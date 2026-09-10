defmodule DoubleEntryLedger.CommandQueue.QueryHelpers do
  @moduledoc """
  Query fragments shared by the command-queue modules so that retry
  eligibility is evaluated on the PostgreSQL clock, not the application node's.
  """

  # Same expression the migration v8 queue trigger uses for
  # `processing_started_at` / `processing_completed_at`.
  @db_now_sql "timezone('UTC', statement_timestamp())"

  @processable_states [:pending, :occ_timeout, :failed]

  @doc """
  Queue states a command can be claimed from. Single source of truth for
  `retry_eligible/1` and `CommandQueue.Scheduling`.
  """
  @spec processable_states() :: [DoubleEntryLedger.CommandQueueItem.state()]
  def processable_states, do: @processable_states

  @doc """
  Query predicate for a queue item that is in a processable state and whose
  retry deadline, if any, has passed on the database clock.

  `queue_item` is the query binding for `CommandQueueItem`.
  """
  defmacro retry_eligible(queue_item) do
    quote do
      unquote(queue_item).status in ^unquote(@processable_states) and
        (is_nil(unquote(queue_item).next_retry_after) or
           unquote(queue_item).next_retry_after <= fragment(unquote(@db_now_sql)))
    end
  end
end
