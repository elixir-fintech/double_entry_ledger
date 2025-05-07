defmodule DoubleEntryLedger.EventQueue.Scheduling do
  @moduledoc """
  This module is responsible for scheduling events in the event queue.
  """

  alias DoubleEntryLedger.Repo

  import DoubleEntryLedger.EventStoreHelper, only: [build_add_error: 2]

  @config Application.compile_env(:double_entry_ledger, :event_queue, [])
  @max_retries Keyword.get(@config, :max_retries, 5)
  @base_delay Keyword.get(@config, :base_retry_delay, 30)
  @max_delay Keyword.get(@config, :max_retry_delay, 3600)
  @doc """
  Sets the next retry time for a failed event using exponential backoff.

  ## Parameters
    - `event` - The event that failed and needs retry scheduling
    - `error` - The error message or reason for failure

  ## Returns
    - `{:ok, updated_event}` - The event with updated retry information
    - `{:error, changeset}` - Error updating the event
  """
  def schedule_retry(event, error, status \\ :failed) do
    if event.retry_count >= @max_retries do
      # Max retries exceeded, mark as dead letter
      mark_as_dead_letter(event, "Max retry count (#{@max_retries}) exceeded: #{error}")
    else
      # Calculate next retry time with exponential backoff
      retry_delay = calculate_retry_delay(event.retry_count)
      now = DateTime.utc_now()
      event
      |> build_add_error(error)
      |> Ecto.Changeset.change(
        status: status,
        processor_id: nil,
        processing_completed_at: now,
        retry_count: event.retry_count + 1,
        next_retry_after: DateTime.add(now, retry_delay, :second)
      )
      |> Repo.update()
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
  def mark_as_dead_letter(event, error) do
    event
    |> build_add_error(error)
    |> Ecto.Changeset.change(
      status: :dead_letter,
      processing_completed_at: DateTime.utc_now()
    )
    |> Repo.update()
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
