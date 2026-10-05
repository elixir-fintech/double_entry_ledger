defmodule DoubleEntryLedger.CommandQueue.Cleanup do
  @moduledoc """
  The lease-fenced writes an `InstanceProcessor` makes to tidy up after its own
  task, and nothing else.

  A processor's worker task can end without having finished its queue row: it
  can report `{:error, :lease_busy}`, or it can crash. Either way the row is
  left `:processing` under this owner and only this owner can move it, because
  the stale sweep is gone. These two writes are what moves it:

    * `{:revert, ids, continuation}` - put the rows back to `:pending` so they
      can be claimed again. The continuation is the *caller's* business, not
      this module's; it is carried through so the caller can match on it.
    * `{:crash_retry, id, reason}` - reschedule the row as `:failed` with the
      shape of the crash recorded against it.

  Both run inside one `Lease.with_grant/3`, so `lock!/3` is the transaction's
  first statement and `refresh_locked!/3` its last, and both report the same
  three outcomes: `{:ok, reverted_ids}`, `:lost` (the ledger moved, nothing was
  written) or `:busy` (the lease row is locked, nothing was written).
  """

  require Logger

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.CommandQueue.Lease.Grant
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  @type t ::
          {:revert, [Ecto.UUID.t()], :resume | :fallback_to_single}
          | {:crash_retry, Ecto.UUID.t(), term()}

  @doc """
  Runs `cleanup` under `grant`, in one lease-fenced transaction.

  Returns `{:ok, reverted_ids}` with the ids whose rows were actually written
  (always `[]` for a crash retry, which writes at most one row and requeues
  nothing), `:lost` when another owner has the ledger, or `:busy` when the
  lease row lock was not granted within `DoubleEntryLedger.CommandQueue.Config.lease_lock_timeout_ms/0`.
  Nothing is written in either of the last two cases.
  """
  @spec perform(t(), Grant.t(), Ecto.Repo.t()) :: {:ok, [Ecto.UUID.t()]} | :lost | :busy
  def perform(cleanup, %Grant{} = grant, repo \\ Repo) do
    {:ok, Lease.with_grant(grant, repo, &apply_cleanup(cleanup, grant, &1))}
  rescue
    Lease.LostError -> :lost
    Lease.BusyError -> :busy
  end

  defp apply_cleanup({:revert, ids, _continuation}, grant, repo),
    do: Enum.flat_map(ids, &revert_if_still_mine(&1, grant, repo))

  defp apply_cleanup({:crash_retry, id, reason}, grant, repo) do
    retry_if_still_mine(id, grant, reason, repo)
    []
  end

  defp revert_if_still_mine(id, grant, repo) do
    case reload_if_still_mine(id, grant, repo) do
      {:ok, command} ->
        repo.update!(Scheduling.build_revert_to_pending(command, nil))
        [id]

      :not_mine ->
        []
    end
  end

  defp retry_if_still_mine(id, grant, reason, repo) do
    case reload_if_still_mine(id, grant, repo) do
      {:ok, command} ->
        command
        |> Scheduling.build_schedule_retry_with_reason(
          "Task crashed: #{failure_shape(reason)}",
          :failed
        )
        |> repo.update!()

      :not_mine ->
        Logger.info(
          "command #{id} is no longer :processing under this owner; not rescheduling after crash"
        )
    end
  end

  # The row as it is now, inside the fenced transaction, but only if this
  # owner's task can still be the one responsible for it. The lease fences
  # other owners; this predicate fences this owner's own ambiguity: a task may
  # have committed and died before reporting, and rescheduling then would
  # retry a committed command (R11.1).
  defp reload_if_still_mine(command_id, grant, repo) do
    case Scheduling.load_commands([command_id], repo) do
      [%Command{command_queue_item: %{status: :processing, processor_id: owner}} = command]
      when owner == grant.owner_id ->
        {:ok, command}

      _ ->
        :not_mine
    end
  end

  # A crashed task's exit reason is `{exception, stacktrace}` and BOTH halves
  # carry the payload: the stacktrace holds call arguments, and an exception
  # struct holds whatever it wrapped — a changeset, and through it the command
  # map, which is transaction amounts and account addresses. `inspect/1` on
  # that dumps all of it, unbounded, into the queue item's errors, from where
  # `Scheduling.emit_persisted_failure/3` puts it into telemetry metadata and a
  # takeover reads it back, so a payload can travel from a crash out to any
  # attached exporter. Persist the SHAPE.
  #
  # The full reason still reaches the `Logger.error` calls in the processor's
  # `:DOWN` handlers, which sit under the operator's own redaction policy.
  @persisted_reason_limit 200

  @doc false
  @spec failure_shape(term()) :: String.t()
  def failure_shape({exception, stacktrace}) when is_list(stacktrace),
    do: failure_shape(exception)

  def failure_shape(%{__struct__: module, __exception__: true} = exception),
    do: bound("#{inspect(module)}: #{Exception.message(exception)}")

  def failure_shape(reason), do: bound(Exception.format_exit(reason))

  defp bound(text) when byte_size(text) <= @persisted_reason_limit, do: text
  defp bound(text), do: String.slice(text, 0, @persisted_reason_limit) <> "…"
end
