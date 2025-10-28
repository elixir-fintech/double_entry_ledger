defmodule DoubleEntryLedger.CommandQueue.Scheduling do
  @moduledoc """
  This module is responsible for scheduling events in the event queue.

  It provides a comprehensive set of functions for managing event lifecycle through the queue:

  * Scheduling and retrying failed events with exponential backoff
  * Managing transitions between different event states (pending, processing, failed, dead letter)
  * Handling special cases like updates waiting for create events
  * Adding errors and tracking retry attempts

  The scheduling system uses configurable parameters:
  * Maximum number of retries before an event is sent to dead letter
  * Base delay for first retry attempt
  * Maximum delay cap to prevent excessive wait times
  * Jitter to prevent thundering herd problems during retries
  """

  alias DoubleEntryLedger.Workers.CommandWorker.UpdateEventError
  import Ecto.Changeset, only: [change: 2, put_assoc: 3]

  alias DoubleEntryLedger.{
    Repo,
    Command,
    EventTransactionLink,
    JournalEventAccountLink,
    Account,
    Transaction
  }

  alias DoubleEntryLedger.Stores.EventStore
  alias DoubleEntryLedger.CommandQueueItem
  alias Ecto.Changeset

  @config Application.compile_env(:double_entry_ledger, :event_queue, [])
  @max_retries Keyword.get(@config, :max_retries, 5)
  @base_delay Keyword.get(@config, :base_retry_delay, 30)
  @max_delay Keyword.get(@config, :max_retry_delay, 3600)

  @processable_states [:pending, :occ_timeout, :failed]

  @doc """
  Sets the next retry time for a failed event using exponential backoff.

  ## Parameters
    - `event` - The event that failed and needs retry scheduling
    - `error` - The error message or reason for failure
    - `status` - The status to set for the event (defaults to `:failed`)

  ## Returns
    - `{:error, updated_event}` - The event with updated retry information
    - `{:error, changeset}` - Error updating the event
  """
  @spec schedule_retry_with_reason(
          Command.t(),
          String.t(),
          CommandQueueItem.state(),
          Ecto.Repo.t()
        ) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  def schedule_retry_with_reason(event, reason, status, repo \\ Repo) do
    case build_schedule_retry_with_reason(event, reason, status) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec mark_as_dead_letter(Command.t(), String.t(), Ecto.Repo.t()) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  def mark_as_dead_letter(event, error, repo \\ Repo) do
    case build_mark_as_dead_letter(event, error) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Claims an event for processing by marking it as being processed by a specific processor.

  This function implements optimistic concurrency control to ensure that only one processor
  can claim an event at a time. It only allows claiming events with status :pending or :occ_timeout.

  ## Parameters
    - `id`: The UUID of the event to claim
    - `processor_id`: A string identifier for the processor claiming the event (defaults to "manual")
    - `repo`: The Ecto repository to use (defaults to Repo)

  ## Returns
    - `{:ok, event}`: If the event was successfully claimed
    - `{:error, :event_not_found}`: If no event with the given ID exists
    - `{:error, :event_already_claimed}`: If the event was claimed by another processor
    - `{:error, :event_not_claimable}`: If the event is not in a claimable state (not pending or occ_timeout)
  """
  @spec claim_event_for_processing(Ecto.UUID.t(), String.t(), Ecto.Repo.t()) ::
          {:ok, Command.t()} | {:error, atom()}
  def claim_event_for_processing(id, processor_id, repo \\ Repo) do
    case EventStore.get_by_id(id) do
      nil ->
        {:error, :event_not_found}

      %{command_queue_item: %{status: state} = eqi} = event when state in @processable_states ->
        try do
          Command.processing_start_changeset(event, processor_id, retry_count_by_status(eqi))
          |> repo.update()
        rescue
          Ecto.StaleEntryError ->
            {:error, :event_already_claimed}
        end

      _ ->
        {:error, :event_not_claimable}
    end
  end

  @doc """
  Builds a changeset to mark an event as processed.

  This function updates the event's status to `:processed` and sets the associated
  transaction ID and timestamps.

  ## Parameters
    - `event` - The Command struct to update
    - `transaction_id` - The UUID of the associated transaction

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for marking the event as processed
  """
  @spec build_mark_as_processed(Command.t()) :: Changeset.t(Command.t())
  def build_mark_as_processed(%{command_queue_item: command_queue_item} = event) do
    event_queue_changeset =
      command_queue_item
      |> CommandQueueItem.processing_complete_changeset()

    event
    |> change(%{})
    |> put_assoc(:command_queue_item, event_queue_changeset)
  end

  @spec build_create_transaction_event_transaction_link(Command.t(), Transaction.t()) ::
          Changeset.t()
  def build_create_transaction_event_transaction_link(%Command{id: event_id}, %Transaction{
        id: transaction_id
      }) do
    %EventTransactionLink{}
    |> EventTransactionLink.changeset(%{
      event_id: event_id,
      transaction_id: transaction_id
    })
  end

  @spec build_create_account_event_account_link(Command.t(), Account.t()) :: Changeset.t()
  def build_create_account_event_account_link(%Command{id: event_id}, %Account{id: account_id}) do
    %JournalEventAccountLink{}
    |> JournalEventAccountLink.changeset(%{
      event_id: event_id,
      account_id: account_id
    })
  end

  @doc """
  Builds a changeset to revert an event to pending state.

  Adds the provided error message to the event's errors list and
  changes the status to `:pending` to allow it to be reprocessed.

  ## Parameters
    - `event` - The event to revert to pending state
    - `error` - The error message to add to the event's errors

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the event
  """
  @spec build_revert_to_pending(Command.t(), any()) :: Changeset.t()
  def build_revert_to_pending(%{command_queue_item: command_queue_item} = event, error) do
    event_queue_changeset =
      command_queue_item
      |> CommandQueueItem.revert_to_pending_changeset(error)

    event
    |> change(%{})
    |> put_assoc(:command_queue_item, event_queue_changeset)
  end

  @doc """
  Builds a changeset to schedule a retry for a failed event.

  Handles both normal retries and terminal failures (dead letter):
  - If the retry count exceeds the configured maximum, marks as dead letter
  - Otherwise, calculates the next retry time using exponential backoff
  - Sets the appropriate event status, clears processor reference, and adds the error

  ## Parameters
    - `event` - The event that needs to be retried
    - `error` - The error message to add to the event's errors
    - `status` - The status to set (usually :failed)

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the event
  """
  @spec build_schedule_retry_with_reason(Command.t(), String.t() | nil, CommandQueueItem.state()) ::
          Changeset.t()
  def build_schedule_retry_with_reason(
        %{command_queue_item: command_queue_item} = event,
        error,
        status
      ) do
    retry_count = command_queue_item.retry_count || 0

    if retry_count >= @max_retries do
      # Max retries exceeded, mark as dead letter
      build_mark_as_dead_letter(
        event,
        "Max retry count (#{@max_retries}) exceeded: #{error || status}"
      )
    else
      # Calculate next retry time with exponential backoff
      retry_delay = calculate_retry_delay(retry_count)

      event_queue_item_changeset =
        command_queue_item
        |> CommandQueueItem.schedule_retry_changeset(
          error,
          status,
          retry_delay
        )

      event
      |> change(%{})
      |> put_assoc(:command_queue_item, event_queue_item_changeset)
    end
  end

  @doc """
  Builds a changeset to schedule the retry of an update event that depends
  on a failed create event.

  Ensures that update events don't retry before their prerequisite create events
  by scheduling them after the create event's next retry time.

  ## Parameters
    - `event` - The update event that needs to be retried
    - `error` - An UpdateEventError struct containing the create event and error details

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the event
  """
  @spec build_schedule_update_retry(Command.t(), UpdateEventError.t()) :: Changeset.t()
  def build_schedule_update_retry(%{command_queue_item: command_queue_item} = event, error) do
    event_queue_item_changeset =
      command_queue_item
      |> CommandQueueItem.schedule_update_retry_changeset(
        error,
        calculate_retry_delay(command_queue_item.retry_count)
      )

    event
    |> change(%{})
    |> put_assoc(:command_queue_item, event_queue_item_changeset)
  end

  @doc """
  Builds a changeset to mark an event as permanently failed (dead letter).

  This is used when an event has failed terminally and should not be retried.
  Adds the provided error message to the event's errors and sets the status
  to `:dead_letter`.

  ## Parameters
    - `event` - The event to mark as dead letter
    - `error` - The error message explaining why the event is being marked as dead letter

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the event
  """
  @spec build_mark_as_dead_letter(Command.t(), String.t()) :: Changeset.t()
  def build_mark_as_dead_letter(%{command_queue_item: command_queue_item} = event, error) do
    event_queue_changeset =
      command_queue_item
      |> CommandQueueItem.dead_letter_changeset(error)

    event
    |> change(%{})
    |> put_assoc(:command_queue_item, event_queue_changeset)
  end

  # Private function to calculate retry delay
  @spec calculate_retry_delay(non_neg_integer()) :: non_neg_integer()
  defp calculate_retry_delay(retry_count) do
    # Exponential backoff: base_delay * 2^retry_count
    delay = @base_delay * :math.pow(2, retry_count)
    delay = min(delay, @max_delay)
    # Add some jitter to prevent thundering herd
    jitter = :rand.uniform(div(trunc(delay), 10) + 1)

    trunc(delay + jitter)
  end

  @spec retry_count_by_status(CommandQueueItem.t()) :: non_neg_integer()
  defp retry_count_by_status(%{status: :pending, retry_count: retry_count}), do: retry_count
  defp retry_count_by_status(%{status: _, retry_count: retry_count}), do: retry_count + 1
end
