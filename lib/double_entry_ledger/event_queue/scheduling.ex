defmodule DoubleEntryLedger.EventQueue.Scheduling do
  @moduledoc """
  This module is responsible for scheduling events in the event queue.
  """

  alias Ecto.Changeset
  alias DoubleEntryLedger.Repo

  import DoubleEntryLedger.EventStoreHelper, only: [build_add_error: 2]

  @config Application.compile_env(:double_entry_ledger, :event_queue, [])
  @max_retries Keyword.get(@config, :max_retries, 5)
  @base_delay Keyword.get(@config, :base_retry_delay, 30)
  @max_delay Keyword.get(@config, :max_retry_delay, 3600)

  @spec schedule_retry(Event.t(), String.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def schedule_retry(event, reason, status \\ :failed) do
    case build_schedule_retry(event, reason, status) |> Repo.update() do
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
    - `event`: The Event struct to update
    - `transaction_id`: The UUID of the associated transaction

  ## Returns
    - `Ecto.Changeset.t()`: The changeset for marking the event as processed
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

  @spec move_to_dead_letter(Event.t(), String.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def move_to_dead_letter(event, reason) do
    case build_mark_as_dead_letter(event, reason) |> Repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec revert_to_pending(Event.t(), String.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def revert_to_pending(event, reason) do
    case build_revert_to_pending(event, reason) |> Repo.update() do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Adds an error to the event's error list and reverts it to pending state.

  ## Parameters
    - `event`: The event to add an error to
    - `error`: Error message or data to add

  ## Returns
    - `{:ok, event}`: If the event was successfully updated
    - `{:error, changeset}`: If the update failed
  """
  @spec build_revert_to_pending(Event.t(), any()) :: Changeset.t()
  def build_revert_to_pending(event, error) do
    event
    |> build_add_error(error)
    |> Changeset.change(status: :pending)
  end

  @doc """
  Sets the next retry time for a failed event using exponential backoff.

  ## Parameters
    - `event` - The event that failed and needs retry scheduling
    - `error` - The error message or reason for failure

  ## Returns
    - `{:ok, updated_event}` - The event with updated retry information
    - `{:error, changeset}` - Error updating the event
  """
  def build_schedule_retry(event, error, status) do
    if event.retry_count >= @max_retries do
      # Max retries exceeded, mark as dead letter
      build_mark_as_dead_letter(event, "Max retry count (#{@max_retries}) exceeded: #{error}")
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
  Marks an event as permanently failed (dead letter).

  ## Parameters
    - `event` - The event to mark as dead letter
    - `reason` - The reason for marking as dead letter

  ## Returns
    - `{:ok, updated_event}` - The event marked as dead letter
    - `{:error, changeset}` - Error updating the event
  """
  def build_mark_as_dead_letter(event, error) do
    event
    |> build_add_error(error)
    |> Changeset.change(
      status: :dead_letter,
      processing_completed_at: DateTime.utc_now()
    )
  end

  # Private function to calculate retry delay
  defp calculate_retry_delay(retry_count) do
    # Exponential backoff: base_delay * 2^retry_count
    delay = @base_delay * :math.pow(2, retry_count)
    delay = min(delay, @max_delay)
    # Add some jitter to prevent thundering herd
    jitter = :rand.uniform(div(trunc(delay), 10) + 1)

    trunc(delay + jitter)
  end
end
