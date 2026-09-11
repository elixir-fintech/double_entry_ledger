defmodule DoubleEntryLedger.CommandQueue.QueryHelpers do
  @moduledoc """
  Query fragments shared by the command-queue modules so that retry
  eligibility is evaluated on the PostgreSQL clock, not the application node's.
  """

  # Same expression the migration 5 queue trigger uses for
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

  @doc """
  Query predicate for a queue item stranded in `:processing`: it has been
  `:processing` for at least `seconds` on the database clock.

  A row whose `processing_started_at` is NULL never matches, because the SQL
  comparison yields NULL.

  `queue_item` is the query binding for `CommandQueueItem`; `seconds` is the
  staleness threshold and must be pinned by the caller.
  """
  defmacro stale_processing(queue_item, seconds) do
    stale_sql = @db_now_sql <> " - (? * interval '1 second')"

    quote do
      unquote(queue_item).status == :processing and
        unquote(queue_item).processing_started_at <=
          fragment(unquote(stale_sql), unquote(seconds))
    end
  end

  @doc """
  Query expression for how many seconds a queue item has been `:processing`,
  measured on the database clock.

  `queue_item` is the query binding for `CommandQueueItem`.
  """
  defmacro processing_age_seconds(queue_item) do
    age_sql = "EXTRACT(EPOCH FROM (" <> @db_now_sql <> " - ?))::double precision"

    quote do
      fragment(unquote(age_sql), unquote(queue_item).processing_started_at)
    end
  end
end
