defmodule DoubleEntryLedger.EventQueue.Scheduling do
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

  alias DoubleEntryLedger.EventWorker.AddUpdateEventError
  alias Ecto.Changeset
  alias DoubleEntryLedger.{Repo, Event}

  import DoubleEntryLedger.EventStoreHelper, only: [build_add_error: 2]

  @config Application.compile_env(:double_entry_ledger, :event_queue, [])
  @max_retries Keyword.get(@config, :max_retries, 5)
  @base_delay Keyword.get(@config, :base_retry_delay, 30)
  @max_delay Keyword.get(@config, :max_retry_delay, 3600)

  @doc """
  Sets the next retry time for a failed event using exponential backoff.

  ## Parameters
    - `event` - The event that failed and needs retry scheduling
    - `status` - The status to set for the event (defaults to `:failed`)

  ## Returns
    - `{:error, updated_event}` - The event with updated retry information
    - `{:error, changeset}` - Error updating the event
  """
  @spec schedule_retry(Event.t(), Event.state(), Ecto.Repo.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def schedule_retry(event, status, repo \\ Repo) do
    case build_schedule_retry_with_reason(event, nil, status) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec schedule_retry_m(Event.t(), Event.state(), Ecto.Repo.t()) ::
          {:ok, {:error, Event.t()}} | {:error, Changeset.t()}
  def schedule_retry_m(event, status, repo \\ Repo) do
    case build_schedule_retry_with_reason(event, nil, status) |> repo.update() do
      {:ok, event} ->
        {:ok, {:error, event}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

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
  @spec schedule_retry_with_reason(Event.t(), String.t(), Event.state(), Ecto.Repo.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def schedule_retry_with_reason(event, reason, status, repo \\ Repo) do
    case build_schedule_retry_with_reason(event, reason, status) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec schedule_retry_with_reason_m(Event.t(), String.t(), Event.state(), Ecto.Repo.t()) ::
         {:ok, {:error, Event.t()}} | {:error, Changeset.t()}
  def schedule_retry_with_reason_m(event, reason, status, repo \\ Repo) do
    case build_schedule_retry_with_reason(event, reason, status) |> repo.update() do
      {:ok, event} ->
        {:ok, {:error, event}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Sets the next retry time for an update event that failed because
  the create event was in :failed state using exponential backoff.
  Makes sure that the next_retry_after is set after the create event's
  next_retry_after.

  ## Parameters
    - `event` - The event that failed and needs retry scheduling
    - `error` - The associated AddUpdateEventError struct that contains the create event

  ## Returns
    - `{:error, updated_event}` - The event with updated retry information
    - `{:error, changeset}` - Error updating the event
  """
  @spec schedule_update_retry(Event.t(), AddUpdateEventError.t(), Ecto.Repo.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def schedule_update_retry(event, reason, repo \\ Repo) do
    case build_schedule_update_retry(event, reason) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Marks an event as permanently failed (dead letter).

  ## Parameters
    - `event` - The event to mark as dead letter
    - `reason` - The reason for marking as dead letter

  ## Returns
    - `{:error, updated_event}` - The event marked as dead letter
    - `{:error, changeset}` - Error updating the event
  """
  @spec move_to_dead_letter(Event.t(), String.t(), Ecto.Repo.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def move_to_dead_letter(event, reason, repo \\ Repo) do
    case build_mark_as_dead_letter(event, reason) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Adds an error to the event's error list and reverts it to pending state.

  ## Parameters
    - `event` - The event to add an error to
    - `error` - Error message or data to add

  ## Returns
    - `{:error, updated_event}` - The event with updated error and status
    - `{:error, changeset}` - Error updating the event
  """
  @spec revert_to_pending(Event.t(), String.t(), Ecto.Repo.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def revert_to_pending(event, reason, repo  \\ Repo) do
    case build_revert_to_pending(event, reason) |> repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Builds a changeset to mark an event as processed.

  This function updates the event's status to `:processed` and sets the associated
  transaction ID and timestamps.

  ## Parameters
    - `event` - The Event struct to update
    - `transaction_id` - The UUID of the associated transaction

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for marking the event as processed
  """
  @spec build_mark_as_processed(Event.t(), Ecto.UUID.t()) :: Changeset.t()
  def build_mark_as_processed(event, transaction_id) do
    now = DateTime.utc_now()

    event
    |> Changeset.change(
      status: :processed,
      processed_at: now,
      processed_transaction_id: transaction_id,
      processing_completed_at: now,
      next_retry_after: nil
    )
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
  @spec build_revert_to_pending(Event.t(), any()) :: Changeset.t()
  def build_revert_to_pending(event, error) do
    event
    |> build_add_error(error)
    |> Changeset.change(status: :pending)
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
  @spec build_schedule_retry_with_reason(Event.t(), String.t() | nil, Event.state()) :: Changeset.t()
  def build_schedule_retry_with_reason(event, error, status) do
    if event.retry_count >= @max_retries do
      # Max retries exceeded, mark as dead letter
      build_mark_as_dead_letter(event, "Max retry count (#{@max_retries}) exceeded: #{error || status}")
    else
      # Calculate next retry time with exponential backoff
      retry_delay = calculate_retry_delay(event.retry_count)
      now = DateTime.utc_now()

      event
      |> build_add_error(error)
      |> Changeset.change(
        status: status,
        processor_id: nil,
        processing_completed_at: now,
        retry_count: event.retry_count + 1,
        next_retry_after: DateTime.add(now, retry_delay, :second)
      )
    end
  end

  @doc """
  Builds a changeset to schedule the retry of an update event that depends
  on a failed create event.

  Ensures that update events don't retry before their prerequisite create events
  by scheduling them after the create event's next retry time.

  ## Parameters
    - `event` - The update event that needs to be retried
    - `error` - An AddUpdateEventError struct containing the create event and error details

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the event
  """
  @spec build_schedule_update_retry(Event.t(), AddUpdateEventError.t()) :: Changeset.t()
  def build_schedule_update_retry(event, error) do
    # Calculate next retry time with exponential backoff
    retry_delay = calculate_retry_delay(event.retry_count)
    now = DateTime.utc_now()
    next_retry_after = DateTime.add(error.create_event.next_retry_after, retry_delay, :second)

    event
    |> build_add_error(error.message)
    |> Changeset.change(
      status: :failed,
      processor_id: nil,
      processing_completed_at: now,
      next_retry_after: next_retry_after
    )
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
  @spec build_mark_as_dead_letter(Event.t(), String.t()) :: Changeset.t()
  def build_mark_as_dead_letter(event, error) do
    event
    |> build_add_error(error)
    |> Changeset.change(
      status: :dead_letter,
      processing_completed_at: DateTime.utc_now()
    )
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
end
