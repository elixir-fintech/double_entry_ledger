defmodule DoubleEntryLedger.CommandQueue.Scheduling do
  @moduledoc """
  Provides scheduling helpers for commands in the command queue.

  It exposes functions that manage the full lifecycle of a command in the queue:

  * Scheduling and retrying failed commands with exponential backoff
  * Managing transitions between different command states (pending, processing, failed, dead letter)
  * Handling special cases like updates waiting for create commands
  * Adding errors and tracking retry attempts

  The scheduling system uses configurable parameters:
  * Maximum number of retries before a command is sent to dead letter
  * Base delay for first retry attempt
  * Maximum delay cap to prevent excessive wait times
  * Jitter to prevent thundering herd problems during retries
  """

  require Logger
  alias DoubleEntryLedger.Telemetry
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError
  import Ecto.Changeset, only: [change: 2, put_assoc: 3]
  import Ecto.Query, only: [from: 2]

  import DoubleEntryLedger.CommandQueue.QueryHelpers,
    only: [retry_eligible: 1, stale_processing: 2, processing_age_seconds: 1]

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.CommandQueue.Lease.Grant
  alias DoubleEntryLedger.CommandQueue.QueryHelpers
  alias DoubleEntryLedger.CommandQueueLeaseRow

  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  alias DoubleEntryLedger.CommandQueueItem
  alias DoubleEntryLedger.Stores.CommandStore
  alias Ecto.Changeset

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()

  @config Application.compile_env(:double_entry_ledger, :command_queue, [])
  @max_retries Keyword.get(@config, :max_retries, 5)
  @base_delay Keyword.get(@config, :base_retry_delay, 30)
  @max_delay Keyword.get(@config, :max_retry_delay, 3600)

  @processable_states QueryHelpers.processable_states()

  @doc """
  Sets the next retry time for a failed command using exponential backoff.

  ## Parameters
    - `command` - The command that failed and needs retry scheduling
    - `error` - The error message or reason for failure
    - `status` - The status to set for the command (defaults to `:failed`)

  ## Returns
    - `{:error, updated_command}` - The command with updated retry information
    - `{:error, changeset}` - Error updating the command

  Raises `Ecto.StaleEntryError` when the `processor_version` fence loses, i.e.
  the claim has since moved to another processor. Callers are expected to
  rescue it and skip the command.

  A command that carries a `lease_grant` is written under the lease
  (`fenced_update/3`) and raises `Lease.LostError` when the ledger has moved
  to another owner, without writing anything.
  """
  @spec schedule_retry_with_reason(
          Command.t(),
          String.t(),
          CommandQueueItem.state(),
          Ecto.Repo.t()
        ) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  def schedule_retry_with_reason(command, reason, status, repo \\ Repo) do
    fenced_update(command, repo, fn r ->
      build_schedule_retry_with_reason(command, reason, status) |> r.update()
    end)
  end

  @doc """
  Marks a command as permanently failed (`:dead_letter`) and persists the change.

  Fenced on the command's `lease_grant` exactly like
  `schedule_retry_with_reason/4`.
  """
  @spec mark_as_dead_letter(Command.t(), String.t(), Ecto.Repo.t()) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  def mark_as_dead_letter(command, error, repo \\ Repo) do
    fenced_update(command, repo, fn r ->
      build_mark_as_dead_letter(command, error) |> r.update()
    end)
  end

  # Both writes happen AFTER the processing Multi rolled back, outside any
  # transaction, so the lease steps inside the Multi cannot cover them. Under a
  # grant the write therefore runs in its own lease-locked transaction: a
  # `LostError` propagates to the worker, which reports `{:error, :lease_lost}`,
  # and nothing is written. With `nil` (the synchronous command-map path, and
  # `InstanceMonitor`'s stale sweep, which loads commands from the database) the
  # write runs exactly as before.
  #
  # Those are the only two clauses, matching `Lease.lock_step/2` and
  # `BatchProcessor.batch_grant/1`: anything else in `lease_grant` raises
  # rather than quietly landing an unfenced write on a ledger this node may
  # have lost.
  #
  # `persisted_failure/1` runs after `with_grant/3` has returned, so a write
  # that rolled back emits no telemetry.
  @spec fenced_update(Command.t(), Ecto.Repo.t(), (Ecto.Repo.t() -> term())) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  defp fenced_update(%Command{lease_grant: %Grant{} = grant}, repo, write) do
    grant
    |> Lease.with_grant(repo, write)
    |> emit_or_return()
  end

  defp fenced_update(%Command{lease_grant: nil}, repo, write) do
    write.(repo) |> emit_or_return()
  end

  defp emit_or_return({:ok, updated_command}), do: persisted_failure(updated_command)
  defp emit_or_return({:error, changeset}), do: {:error, changeset}

  @doc """
  Claims a single command for processing under the lease `grant`.

  The claim is `claim_batch_for_processing/3` applied to one command, so it
  runs in the same single transaction serialized on the ledger's lease row:
  `Lease.lock!/3`, the claim UPDATE, `Lease.refresh_locked!/3`. Status and
  retry deadline are enforced together inside that atomic UPDATE
  (`QueryHelpers.retry_eligible/1`, evaluated on the database clock), so a
  command whose `next_retry_after` has not elapsed is never claimed early and
  no check-then-claim window exists.

  The status load before the claim only short-circuits the obvious cases. A
  zero-row UPDATE is no longer ambiguous: the lease proves no competing
  claimer exists, so it can only mean the row is not claimable.

  ## Parameters
    - `id`: The UUID of the command to claim
    - `grant`: The `Lease.Grant` proving this node owns the ledger; its
      `owner_id` is stamped on the row
    - `repo`: The Ecto repository to use (defaults to Repo)

  ## Returns
    - `{:ok, command}`: Claimed, carrying the refreshed `command_queue_item`
      (`:processing`, `processor_id` stamped, `processor_version` advanced,
      `retry_count` bumped for a retry, `next_retry_after` cleared) and
      `lease_grant` set to `grant`
    - `{:error, :command_not_found}`: If no command with the given ID exists
    - `{:error, :command_not_claimable}`: If the command is not in a claimable
      state, or its retry deadline is still in the database's future
    - `{:error, :lease_lost}`: Another owner has the ledger; nothing was written
    - `{:error, :lease_busy}`: The lease row lock was not granted within
      `Config.lease_lock_timeout_ms/0`; nothing was written

  Only `Lease.BusyError` becomes `:lease_busy`, which is `Lease.lock!/3`'s
  narrow rule rather than the wider one `acquire/4`, `renew/3` and `release/3`
  apply through `Lease.transient?/1`. The reason is structural, and covers all
  three statements this `rescue` spans, not just the lock: every writer that
  touches queue rows under the lease takes the lease row first, and none waits
  on the lease row while already holding a queue row. No lock cycle containing
  this transaction can therefore form, and the queue runs at READ COMMITTED,
  where a serialization failure cannot arise either. A `deadlock_detected` or
  `serialization_failure` here means a writer outside the lease discipline, or
  a misconfigured isolation level, and must crash the caller visibly instead
  of being retried as routine contention (R11.2).

  Note that only the wait for the lease row is bounded.
  `Lease.with_lock_timeout/2` restores the caller's `lock_timeout` before
  `lock!/3` returns, so the claim UPDATE waits on queue rows with the
  connection default, which is normally unlimited. That matters for as long as
  queue writers outside the lease discipline still exist (through Task 11).
  """
  @spec claim_command_for_processing(Ecto.UUID.t(), Grant.t(), Ecto.Repo.t()) ::
          {:ok, Command.t()} | {:error, atom()}
  def claim_command_for_processing(id, %Grant{} = grant, repo \\ Repo) do
    case CommandStore.get_by_id(id) do
      nil ->
        {:error, :command_not_found}

      %{command_queue_item: %{status: state}} = command when state in @processable_states ->
        case claim_batch_for_processing([command], grant, repo) do
          [claimed] -> {:ok, claimed}
          [] -> {:error, :command_not_claimable}
        end

      _ ->
        {:error, :command_not_claimable}
    end
  rescue
    Lease.LostError -> {:error, :lease_lost}
    Lease.BusyError -> {:error, :lease_busy}
  end

  @doc """
  Claims a batch of commands for processing under the lease `grant`. This is
  the only claim statement: `claim_command_for_processing/3` runs it with a
  single command.

  Everything happens in one transaction serialized on the ledger's lease row,
  opened by `Lease.with_grant/3`: `Lease.lock!/3` is its first statement and
  `Lease.refresh_locked!/3` its last, with the claim UPDATE in between. The
  lock is therefore held for the whole claim, so a takeover by another node
  cannot interleave with it, and a rolled-back claim leaves the queue rows
  untouched for the successor.

  Going through `with_grant/3` rather than opening the transaction here is
  what makes "lock first" enforceable rather than merely true. `lock!/3` on
  its own asserts only that it is *inside* a transaction; a caller that wrapped
  a claim in its own transaction would have `repo.transaction/1` join that one,
  leaving the lease lock somewhere in the middle with queue rows already
  written and no test able to see it. `with_grant/3` carries
  `require_no_transaction!`, so such a caller raises `ArgumentError` instead.

  For every command: status → `:processing`, stamps the grant's `owner_id` as
  `processor_id`, clears `next_retry_after`, advances `processor_version`, and
  bumps `retry_count` (unchanged for `:pending`, `+1` otherwise). A single
  conditional bulk update applies the appropriate retry-count rule to each
  row. The queue trigger stamps `processing_started_at`.

  `processor_version` is advanced here only until Task 11 removes the column:
  the lease row lock, not the per-row fence, is now the real concurrency
  check. The status and retry-time guards in the UPDATE skip a command that is
  not claimable or is rescheduled for a future retry.

  Returns the subset of `commands` that were actually claimed, in the same
  order, each with a refreshed `command_queue_item` and `lease_grant` set to
  `grant`, so processing can fence on the same grant. `Lease.LostError` and
  `Lease.BusyError` propagate.
  """
  @spec claim_batch_for_processing([Command.t()], Grant.t(), Ecto.Repo.t()) :: [Command.t()]
  def claim_batch_for_processing(commands, grant, repo \\ Repo)

  def claim_batch_for_processing([], _grant, _repo), do: []

  def claim_batch_for_processing(commands, %Grant{} = grant, repo) do
    ids = Enum.map(commands, & &1.id)

    {_count, claimed_items} =
      Lease.with_grant(grant, repo, fn repo ->
        repo.update_all(claim_query(ids, grant.owner_id), [])
      end)

    items_by_command_id = Map.new(claimed_items, &{&1.command_id, &1})

    claimed_commands =
      commands
      |> Enum.filter(&Map.has_key?(items_by_command_id, &1.id))
      |> Enum.map(
        &%{&1 | command_queue_item: Map.fetch!(items_by_command_id, &1.id), lease_grant: grant}
      )

    # One `[:command, :claim]` event per claimed command
    # (Telemetry.command_claim/1), single-command claims included.
    Enum.each(claimed_commands, fn command ->
      Telemetry.command_claim(%{
        command_id: command.id,
        instance_id: command.instance_id,
        processor_id: grant.owner_id,
        trace_context: command.trace_context
      })
    end)

    claimed_commands
  end

  defp claim_query(ids, processor_id) do
    from(eqi in CommandQueueItem,
      prefix: ^@schema_prefix,
      where: eqi.command_id in ^ids and retry_eligible(eqi),
      update: [
        set: [
          status: :processing,
          processor_id: ^processor_id,
          next_retry_after: nil,
          retry_count:
            fragment(
              "? + CASE WHEN ? IN ('occ_timeout', 'failed') THEN 1 ELSE 0 END",
              eqi.retry_count,
              eqi.status
            )
        ],
        inc: [processor_version: 1]
      ],
      select: eqi
    )
  end

  @doc """
  Query for up to `limit` ids of the next processable commands for
  `instance_id`, lowest queue position first.

  Retry eligibility is evaluated on the database clock
  (`QueryHelpers.retry_eligible/1`). Drives off the partial index
  `idx_command_queue_items_in_flight` (migration 5):
  `(instance_id, queue_position) WHERE status IN ('pending', 'occ_timeout',
  'failed')`. `InstanceProcessor` runs it to refill its in-memory buffer.
  """
  @spec next_command_ids_query(Ecto.UUID.t(), pos_integer()) :: Ecto.Query.t()
  def next_command_ids_query(instance_id, limit) do
    from(eqi in CommandQueueItem,
      prefix: ^@schema_prefix,
      where: eqi.instance_id == ^instance_id and retry_eligible(eqi),
      order_by: [asc: eqi.queue_position],
      limit: ^limit,
      select: eqi.command_id
    )
  end

  @doc """
  Query for the distinct ids of instances with an eligible or `:processing`
  row whose lease is missing, released or expired; `:processing` rows are
  included so a ledger whose owner died with nothing else queued is still
  taken over.

  `released_at` is tested in its own right rather than relying on
  `Lease.release/3` also stamping `expires_at` in the same statement: a
  gracefully drained ledger must be offered to a successor immediately, and
  that must not depend on how release happens to be worded.

  Retry eligibility and lease expiry are both evaluated on the database clock
  (`QueryHelpers.retry_eligible/1`, `statement_timestamp()`), so no
  application timestamp is bound. `InstanceMonitor` runs it on every poll; a
  ledger another node already owns is simply not offered.
  """
  @spec instances_with_processable_commands_query() :: Ecto.Query.t()
  def instances_with_processable_commands_query do
    from(cqi in CommandQueueItem,
      prefix: ^@schema_prefix,
      left_join: l in CommandQueueLeaseRow,
      on: l.instance_id == cqi.instance_id,
      where:
        (retry_eligible(cqi) or cqi.status == :processing) and
          (is_nil(l.instance_id) or not is_nil(l.released_at) or
             l.expires_at <= fragment("timezone('UTC', statement_timestamp())")),
      select: cqi.instance_id,
      distinct: true
    )
  end

  @doc """
  Query for up to `limit` commands stranded in `:processing`: rows claimed at
  least `stale_after_seconds` ago on the database clock whose owner never
  reported back (`QueryHelpers.stale_processing/2`). Oldest claim first.

  Selects `{command, queue_item, seconds_in_processing}` so the caller can
  rebuild the command with its queue item and report how long the row was
  stuck without consulting the application clock. `InstanceMonitor` runs it on
  every poll and routes each row through the normal failure path.
  """
  @spec stale_processing_commands_query(non_neg_integer(), pos_integer()) :: Ecto.Query.t()
  def stale_processing_commands_query(stale_after_seconds, limit) do
    from(c in Command,
      join: cqi in CommandQueueItem,
      prefix: ^@schema_prefix,
      on: c.id == cqi.command_id,
      where: stale_processing(cqi, ^stale_after_seconds),
      order_by: [asc: cqi.processing_started_at],
      limit: ^limit,
      select: {c, cqi, processing_age_seconds(cqi)}
    )
  end

  @doc """
  Builds a changeset to mark a command as processed.

  This function updates the queue item's status to `:processed` and clears its
  retry timestamp. The queue trigger stamps `processing_completed_at`.

  ## Parameters
    - `command` - The Command struct to update

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for marking the command as processed
  """
  @spec build_mark_as_processed(Command.t()) :: Changeset.t(Command.t())
  def build_mark_as_processed(%{command_queue_item: command_queue_item} = command) do
    command_queue_changeset =
      command_queue_item
      |> CommandQueueItem.processing_complete_changeset()

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_changeset)
  end

  @doc """
  Builds a changeset to revert a command to the pending state.

  Adds the provided error message to the queue item's errors list and
  changes the status to `:pending` to allow it to be reprocessed.

  ## Parameters
    - `command` - The command to revert to pending state
    - `error` - The error message to add to the command's errors

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_revert_to_pending(Command.t(), any()) :: Changeset.t()
  def build_revert_to_pending(%{command_queue_item: command_queue_item} = command, error) do
    command_queue_changeset =
      command_queue_item
      |> CommandQueueItem.revert_to_pending_changeset(error)

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_changeset)
  end

  @doc """
  Builds a changeset to schedule a retry for a failed command.

  Handles both normal retries and terminal failures (dead letter):
  - If the retry count exceeds the configured maximum, marks as dead letter
  - Otherwise, calculates the retry delay using exponential backoff and writes
    it as `retry_delay_seconds`; PostgreSQL computes `next_retry_after` from
    it on the database clock when the changeset is persisted
  - Sets the appropriate command status, clears processor reference, and adds the error

  ## Parameters
    - `command` - The command that needs to be retried
    - `error` - The error message to add to the command's errors
    - `status` - The status to set (usually :failed)

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_schedule_retry_with_reason(
          Command.t(),
          String.t() | nil,
          CommandQueueItem.state(),
          keyword()
        ) :: Changeset.t()
  def build_schedule_retry_with_reason(
        %{command_queue_item: command_queue_item} = command,
        error,
        status,
        opts \\ []
      ) do
    retry_count = command_queue_item.retry_count || 0

    if retry_count >= @max_retries do
      build_mark_as_dead_letter(
        command,
        "Max retry count (#{@max_retries}) exceeded: #{error || status}"
      )
    else
      # `retry_delay: 0` is used by lease takeover so orphaned rows are
      # eligible at once; everything else gets exponential backoff.
      retry_delay =
        Keyword.get_lazy(opts, :retry_delay, fn -> calculate_retry_delay(retry_count) end)

      command_queue_item_changeset =
        CommandQueueItem.schedule_retry_changeset(command_queue_item, error, status, retry_delay)

      command
      |> change(%{})
      |> put_assoc(:command_queue_item, command_queue_item_changeset)
    end
  end

  @doc """
  Reschedules every `:processing` row on `instance_id`, whatever its
  `processor_id`, as `:failed` with a zero retry delay, and returns the
  updated commands with their queue items, lowest queue position first.

  Called by `DoubleEntryLedger.CommandQueue.Lease.acquire/4` inside the
  transaction that already holds the lease row lock, which proves no live
  lease-aware owner exists, so every `:processing` row is an orphan (a dead
  owner, a rolling deploy in progress, or a pre-lease manual call). Raises on
  any failure, including `Ecto.StaleEntryError`, so the caller's transaction
  rolls back. Emits nothing; the caller emits after commit.
  """
  @spec reschedule_orphaned_processing!(Ecto.UUID.t(), Ecto.Repo.t()) :: [Command.t()]
  def reschedule_orphaned_processing!(instance_id, repo) do
    from(c in Command,
      prefix: ^@schema_prefix,
      join: cqi in CommandQueueItem,
      on: cqi.command_id == c.id,
      where: cqi.instance_id == ^instance_id and cqi.status == :processing,
      order_by: [asc: cqi.queue_position],
      preload: [command_queue_item: cqi]
    )
    |> repo.all()
    |> Enum.map(fn command ->
      reason =
        "orphaned by lease acquisition; previous processor " <>
          inspect(command.command_queue_item.processor_id)

      command
      |> build_schedule_retry_with_reason(reason, :failed, retry_delay: 0)
      |> repo.update!()
    end)
  end

  @doc """
  Builds a changeset to schedule the retry of an update command that depends
  on a failed create command.

  Ensures that update commands don't retry before their prerequisite create commands
  by scheduling them after the create command's next retry time. When the create
  command has no retry time, only the delay is written and PostgreSQL computes
  `next_retry_after` on the database clock.

  ## Parameters
    - `command` - The update command that needs to be retried
    - `error` - An UpdateCommandError struct containing the create command and error details

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_schedule_update_retry(Command.t(), UpdateCommandError.t()) :: Changeset.t()
  def build_schedule_update_retry(%{command_queue_item: command_queue_item} = command, error) do
    command_queue_item_changeset =
      command_queue_item
      |> CommandQueueItem.schedule_update_retry_changeset(
        error,
        calculate_retry_delay(command_queue_item.retry_count)
      )

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_item_changeset)
  end

  @doc """
  Builds a changeset to mark a command as permanently failed (dead letter).

  This is used when a command has failed terminally and should not be retried.
  Adds the provided error message to the command's errors and sets the status
  to `:dead_letter`.

  ## Parameters
    - `command` - The command to mark as dead letter
    - `error` - The error message explaining why the command is being marked as dead letter

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_mark_as_dead_letter(Command.t(), String.t()) :: Changeset.t()
  def build_mark_as_dead_letter(%{command_queue_item: command_queue_item} = command, error) do
    command_queue_changeset =
      command_queue_item
      |> CommandQueueItem.dead_letter_changeset(error)

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_changeset)
  end

  @doc "Emits telemetry for a persisted command failure and returns its worker error tuple."
  @spec persisted_failure(Command.t()) :: {:error, Command.t()}
  def persisted_failure(
        %Command{command_queue_item: %{errors: [%{message: message} | _], status: status}} =
          command
      ) do
    emit_persisted_failure(command, status, message)
    {:error, command}
  end

  @doc "Emits retry or dead-letter telemetry after a failure transition is persisted."
  @spec emit_persisted_failure(Command.t(), CommandQueueItem.state(), String.t()) :: :ok
  def emit_persisted_failure(command, :dead_letter, message) do
    Logger.error("dead-lettering command #{command.id}: #{message}")

    Telemetry.command_dead_letter(%{
      command_id: command.id,
      instance_id: command.instance_id,
      error: message,
      trace_context: command.trace_context
    })
  end

  def emit_persisted_failure(command, status, message) when status in [:failed, :occ_timeout] do
    Logger.warning("command #{command.id} persisted with #{status} status: #{message}")

    Telemetry.command_retry(%{
      command_id: command.id,
      instance_id: command.instance_id,
      status: status,
      retry_count: command.command_queue_item.retry_count || 0,
      trace_context: command.trace_context
    })
  end

  def emit_persisted_failure(_command, _status, _message), do: :ok

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
