defmodule DoubleEntryLedger.CommandQueue.InstanceProcessor do
  @moduledoc """
  Handles processing of commands for a specific instance.

  The `InstanceProcessor` is responsible for fetching, processing, and updating the status
  of commands belonging to a single instance. It is started dynamically by the
  `InstanceMonitor` when there are queued commands to process.

  ## Responsibilities

    * Hold the ledger's lease for its whole lifetime: it is handed a
      `Lease.Grant` at start, heartbeats it while idle, lets its transactions
      refresh it while busy, releases it on drain and on shutdown, and stops
      the moment another owner has taken the ledger.
    * Fetch pending, failed, or timed-out commands for the assigned instance.
    * Process each command and update its status in the database.
    * Handle retries and error cases according to command queue logic.
    * Ensure only one processor runs per instance at a time (enforced via Registry).
    * Buffer command ids in memory (`:command_queue` key `:pending_fetch_limit`,
      default 64) and drain that buffer before hitting the database again.
    * When the `:command_queue` key `:batch_enabled` is set, process up to
      `:batch_size` (default 8) commands per batch; a batch that hits an
      unexpected database error is reverted to `:pending` and its commands are
      flagged `force_single` so they drain one at a time.

  Worker tasks (single command and batch) run under
  `DoubleEntryLedger.CommandQueue.WorkerSupervisor`, unlinked and tracked by
  `Process.monitor/1`, so they belong to the supervision tree and die with the
  queue supervisor on application stop.

  This module is typically supervised under the `InstanceSupervisor` as a dynamic child.
  """
  use GenServer, restart: :temporary, shutdown: 10_000
  require Logger

  alias DoubleEntryLedger.{BatchProcessor, Command, Telemetry}
  alias DoubleEntryLedger.CommandQueue.{Cleanup, Config, Lease, Scheduling}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Workers.CommandWorker

  @worker_supervisor DoubleEntryLedger.CommandQueue.WorkerSupervisor

  # Client API

  @doc """
  Starts an instance processor for the specified instance.

  ## Parameters
    - `opts` - Keyword list of options where:
      - `:instance_id` - Required UUID of the instance to process commands for
      - `:grant` - Required `Lease.Grant` proving this node owns the ledger.
        Acquisition belongs to the `InstanceMonitor`; the processor only holds,
        renews and releases what it was handed.

  ## Returns
    - `{:ok, pid}` - Successfully started the processor
    - `{:error, reason}` - Failed to start the processor
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    grant = Keyword.fetch!(opts, :grant)
    worker = Keyword.get(opts, :worker, CommandWorker)
    batch_processor = Keyword.get(opts, :batch_processor, BatchProcessor)
    name = via_tuple(instance_id)

    GenServer.start_link(
      __MODULE__,
      %{
        instance_id: instance_id,
        grant: grant,
        worker: worker,
        batch_processor: batch_processor
      },
      name: name
    )
  end

  @doc """
  Creates a via tuple for registry-based naming.

  ## Parameters
    - `instance_id` - UUID of the instance to create a name for

  ## Returns
    - A tuple in the format expected by Registry for process lookup
  """
  @spec via_tuple(Ecto.UUID.t()) :: {:via, module(), {module(), Ecto.UUID.t()}}
  def via_tuple(instance_id) do
    {:via, Registry, {DoubleEntryLedger.CommandQueue.Registry, instance_id}}
  end

  # Server Callbacks

  @impl true
  def init(%{
        instance_id: instance_id,
        grant: grant,
        worker: worker,
        batch_processor: batch_processor
      }) do
    # Not only the supervisor's job. `CommandQueue.Supervisor.init/1` is the
    # other caller, but it never runs when `:start_command_queue` is false —
    # the perf and test environments, and the documented setting for embedding
    # the ledger without the queue — and those are exactly the setups that
    # start a processor by hand with the batch size coming off an environment
    # variable. `:batch_size` and `:pending_fetch_limit` are read per dispatch
    # round, so a typo there is a live mistake, and neither is clamped: a zero
    # batch size dispatches nothing and re-sends `:process_next` forever. Fail
    # the start, naming the key.
    Config.validate!()

    Process.flag(:trap_exit, true)
    Logger.info("Starting command processor for instance #{instance_id} as #{grant.owner_id}")
    Telemetry.instance_processor_start(%{instance_id: instance_id, owner_id: grant.owner_id})

    # Schedule immediate processing
    send(self(), :process_next)
    schedule_renew()

    {:ok,
     %{
       instance_id: instance_id,
       grant: grant,
       lease_lost: false,
       released: false,
       # What `terminate/2` reports if it has to release: `:shutdown` unless
       # the processor stopped itself for a reason of its own — a drain whose
       # release was busy, or a cleanup that stalled.
       release_reason: :shutdown,
       worker: worker,
       batch_processor: batch_processor,
       # The one task this processor may have running, and everything about it:
       # nil, {:single, command_id, ref, pid} or {:batch, commands, ref, pid}.
       # One field rather than five that were only ever written and cleared
       # together, so "a single command and a batch are mutually exclusive" is
       # structure rather than clause order, and a lost lease provably cannot
       # coexist with a live task: every caller of `lease_lost/2` passes a state
       # that went through `clear_task/1`.
       in_flight: nil,
       pending_ids: [],
       # A cleanup (revert or crash retry) that found the lease row locked and
       # must be retried before any further work is dispatched.
       pending_cleanup: nil,
       # Consecutive `:busy` outcomes for the cleanup above, bounded by
       # `@max_cleanup_busy_retries`. Reset by any cleanup that lands.
       cleanup_attempts: 0,
       # Command ids that must be processed one-at-a-time via the
       # single-cmd path instead of being re-batched. Populated when a
       # batch write hits an unexpected DB error and we fall back to
       # per-command processing (see the {:batch_complete, {:error, _}}
       # handler). Always a subset of `pending_ids`.
       force_single: MapSet.new()
     }}
  end

  @impl true
  def handle_info(
        :process_next,
        %{pending_cleanup: nil, in_flight: nil, pending_ids: [_ | _]} = state
      ) do
    dispatch_pending(state)
  end

  def handle_info(:process_next, %{pending_cleanup: nil, in_flight: nil} = state) do
    # Drain from the in-memory buffer first; only hit the DB to refill
    # when it's empty. This amortizes the find_next SELECT cost across
    # `Config.pending_fetch_limit/0` commands per round-trip.
    case find_next_command_ids(state.instance_id, Config.pending_fetch_limit()) do
      [] ->
        Logger.info(
          "No more commands to process for instance #{state.instance_id}, shutting down"
        )

        Telemetry.instance_processor_stop(%{instance_id: state.instance_id})
        drain_release(state)

      ids ->
        dispatch_pending(%{state | pending_ids: ids})
    end
  end

  # Idle: renew. :busy is contention, never loss; :lost is the only loss signal.
  def handle_info(:renew_lease, %{in_flight: nil, grant: grant} = state) do
    case Lease.renew(grant) do
      :ok ->
        Telemetry.lease_renewed(Lease.grant_metadata(grant, %{}))
        schedule_renew()
        {:noreply, state}

      :busy ->
        Logger.debug("lease heartbeat for #{state.instance_id} found the row locked")
        schedule_renew()
        {:noreply, state}

      :lost ->
        lease_lost(state, :renewal)
    end
  end

  # In flight: the transaction refreshes the expiry itself; a locked row would
  # only read as :busy, so do not touch the database.
  def handle_info(:renew_lease, state) do
    schedule_renew()
    {:noreply, state}
  end

  # Either a task is still running, or a pending cleanup owns the queue row this
  # processor last touched. With the stale sweep gone only this owner can clean
  # that row up, so nothing new is dispatched until the cleanup lands (R12.1).
  def handle_info(:process_next, state), do: {:noreply, state}

  def handle_info(:retry_cleanup, %{pending_cleanup: nil} = state), do: {:noreply, state}

  def handle_info(:retry_cleanup, %{pending_cleanup: cleanup} = state),
    do: run_cleanup(cleanup, state)

  def handle_info({:processing_complete, command_id, {:error, :lease_lost}}, state) do
    Logger.warning("command #{command_id}: lease lost during processing")
    lease_lost(clear_task(state), :transaction)
  end

  def handle_info({:processing_complete, command_id, {:error, :lease_busy}}, state) do
    run_cleanup({:revert, [command_id], :resume}, clear_task(state))
  end

  def handle_info({:processing_complete, command_id, result}, state) do
    case result do
      {:ok, _, _} ->
        Logger.info("Successfully processed command #{command_id}")

      {:error, reason} ->
        Logger.warning("Failed to process command #{command_id}: #{inspect(reason)}")

        # Note: the error is already recorded in the command by CommandWorker.process_command_with_id
    end

    # Command processing completed, check for more commands
    continue(clear_task(state))
  end

  def handle_info({:batch_complete, {:ok, _} = outcomes}, state) do
    log_outcomes(outcomes)
    continue(clear_task(state))
  end

  def handle_info({:batch_complete, {:error, :lease_lost}}, state) do
    lease_lost(clear_task(state), :transaction)
  end

  def handle_info(
        {:batch_complete, {:error, :lease_busy}},
        %{in_flight: {:batch, batch, _ref, _task_pid}} = state
      ) do
    run_cleanup({:revert, Enum.map(batch, & &1.id), :resume}, clear_task(state))
  end

  # Unexpected (non-stale) DB error from the batched write: the whole
  # transaction rolled back, so nothing in the batch was persisted. Per
  # the plan (§8.3) fall back to per-command processing for this batch so
  # a single offending command is isolated instead of poisoning the whole
  # batch forever. Revert the claimed rows to :pending (retry_count set at
  # claim is preserved, and re-claiming from :pending won't double-bump),
  # then flag them `force_single` and re-queue them at the front.
  def handle_info(
        {:batch_complete, {:error, _reason} = outcomes},
        %{in_flight: {:batch, batch, _ref, _task_pid}} = state
      ) do
    log_outcomes(outcomes)
    fall_back_to_single(clear_task(state), batch)
  end

  # Batch task crashed — fall back to the single-command path so one
  # deterministically crashing command cannot consume the retry budget of
  # otherwise healthy neighbours.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight: {:batch, batch, ref, _task_pid}, instance_id: instance_id} = state
      ) do
    Logger.error(
      "Batch task crashed for instance #{instance_id} (#{length(batch)} cmds): #{inspect(reason)}"
    )

    fall_back_to_single(clear_task(state), batch)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight: {:single, command_id, ref, _task_pid}, instance_id: instance_id} = state
      ) do
    Logger.error(
      "Command task crashed for command #{command_id} on instance #{instance_id}: #{inspect(reason)}"
    )

    run_cleanup({:crash_retry, command_id, reason}, clear_task(state))
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # :DOWN from an unrelated or already-handled process, ignore
    {:noreply, state}
  end

  # `init/1` traps exits so `terminate/2` runs on shutdown. The parent's exit is
  # handled by `GenServer` itself; anything else linked to this process would
  # otherwise arrive here with no clause and kill the processor with a function
  # clause error — the failure mode this whole task exists to prevent. Worker
  # tasks are deliberately unlinked, so reaching either of these is already a
  # surprise: log it and keep the lease.
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning(
      "instance #{state.instance_id} trapped an exit from #{inspect(pid)}: #{inspect(reason)}"
    )

    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warning(
      "instance #{state.instance_id} ignoring unexpected message: #{inspect(message)}"
    )

    {:noreply, state}
  end

  # A busy release is not a release: the lease would stay live for up to
  # `lease_ttl` on a ledger nobody is working. Leave `released` unset so
  # `terminate/2` tries once more, still reporting `:drained`.
  defp drain_release(state) do
    case Lease.release(state.grant, :drained) do
      :busy -> {:stop, :normal, %{state | release_reason: :drained}}
      _released_or_noop -> {:stop, :normal, %{state | released: true}}
    end
  end

  @impl true
  def terminate(_reason, %{released: true}), do: :ok
  def terminate(_reason, %{lease_lost: true}), do: :ok

  # A task still in flight owns a queue row under this lease. Kill it and wait
  # for it to be gone before releasing, so the successor never starts while the
  # predecessor's transaction can still commit.
  def terminate(_reason, %{in_flight: {_tag, _work, _task_ref, pid}, grant: grant} = state) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> Lease.release(grant, state.release_reason)
    after
      5_000 ->
        Logger.warning("task for #{state.instance_id} did not stop; leaving the lease to expire")
    end

    :ok
  end

  def terminate(_reason, %{grant: grant, release_reason: reason}) do
    Lease.release(grant, reason)
    :ok
  end

  defp schedule_renew do
    Process.send_after(self(), :renew_lease, max(div(Config.lease_ttl(), 3), 1) * 1_000)
  end

  defp continue(state) do
    send(self(), :process_next)
    {:noreply, state}
  end

  defp lease_lost(%{grant: grant} = state, source) do
    Logger.warning("lease for instance #{state.instance_id} lost (#{source}); stopping")
    Telemetry.lease_lost(Lease.grant_metadata(grant, %{source: source}))
    {:stop, :normal, %{state | lease_lost: true}}
  end

  # A cleanup (revert or crash retry) is a lease-fenced write by this owner.
  # LostError: the ledger moved, stop. BusyError: the row is locked; keep the
  # cleanup and retry it by timer, dispatching nothing meanwhile, because
  # with the stale sweep gone only this owner can clean the row up (R12.1).
  # Success: clear and continue.
  defp run_cleanup(cleanup, state) do
    case Cleanup.perform(cleanup, state.grant) do
      {:ok, reverted_ids} ->
        send(self(), :process_next)

        {:noreply,
         apply_continuation(cleanup, reverted_ids, %{
           state
           | pending_cleanup: nil,
             cleanup_attempts: 0
         })}

      :busy ->
        retry_or_give_up(cleanup, %{state | cleanup_attempts: state.cleanup_attempts + 1})

      :lost ->
        lease_lost(%{state | pending_cleanup: nil}, :transaction)
    end
  end

  # Whoever holds the lease row is not a successor — a successor would have
  # taken the lease and the next cleanup would read `:lost`, not `:busy`. So
  # the retry has no self-resolving deadline of its own, and without a bound
  # this processor heartbeats the lease, dispatches nothing and waits forever
  # (R12.1 says only this owner may clean the row up).
  #
  # The bound is a stop rather than a shrug: the queue row is left `:processing`
  # under this owner, and the one thing that can rescue it is another owner's
  # acquisition, which reschedules every `:processing` row on the ledger. So
  # giving up the ledger IS the escalation. `terminate/2` releases the lease
  # with `:cleanup_stalled`, which stamps the row expired so a successor may
  # acquire it.
  #
  # Not a promise of immediate rescue. The lock holder this owner could not get
  # past blocks the successor's acquisition too, so until it lets go the
  # successor reads `:busy` and backs off, and the release above reads `:busy`
  # as well, leaving the lease to expire by TTL — the designed backstop for
  # every unreleased lease. What the bound buys is a processor that stops and
  # says so, and a ledger other nodes may attempt, instead of one node
  # heartbeating a lease it cannot use and dispatching nothing.
  @max_cleanup_busy_retries 10

  defp retry_or_give_up(cleanup, %{cleanup_attempts: attempts} = state)
       when attempts >= @max_cleanup_busy_retries do
    Logger.error(
      "cleanup for instance #{state.instance_id} found the lease row locked " <>
        "#{attempts} times in a row; giving up the ledger so a successor can " <>
        "reschedule what this owner left :processing"
    )

    Telemetry.cleanup_stalled(
      Lease.grant_metadata(state.grant, %{attempts: attempts, cleanup: elem(cleanup, 0)})
    )

    {:stop, :normal, %{state | pending_cleanup: nil, release_reason: :cleanup_stalled}}
  end

  defp retry_or_give_up(cleanup, state) do
    Logger.debug("cleanup for #{state.instance_id} found the lease row locked; retrying")
    Process.send_after(self(), :retry_cleanup, Config.lease_lock_timeout_ms())
    {:noreply, %{state | pending_cleanup: cleanup}}
  end

  # The continuation decides what happens to the reverted ids (R13.1).
  #
  # :resume puts EVERY id of the revert back at the head of the queue, not only
  # the reverted ones. A busy result is most often a busy CLAIM, which wrote
  # nothing: the row is still `:pending`, the revert has nothing to move, and
  # requeueing only `reverted` would drop a command that dispatch had already
  # popped behind everything still buffered — a create overtaken by its update.
  # Requeueing an id that was not reverted is harmless whatever its row holds:
  # the claim is the only way back into processing, and its status and
  # retry-deadline guards skip a row that is not claimable. That matters for
  # the one busy result that can follow a committed write, a batch whose split
  # committed its first half before the second half timed out on the lease row.
  #
  # :fallback_to_single requeues and flags only what was actually reverted, so
  # a deterministically failing batch drains one at a time instead of being
  # reassembled forever, and rows a batch had committed are neither requeued
  # nor flagged.
  defp apply_continuation({:crash_retry, _id, _reason}, _reverted, state), do: state

  defp apply_continuation({:revert, ids, :resume}, _reverted, state),
    do: %{state | pending_ids: ids ++ state.pending_ids}

  defp apply_continuation({:revert, _ids, :fallback_to_single}, reverted, state) do
    %{
      state
      | pending_ids: reverted ++ state.pending_ids,
        force_single: MapSet.union(state.force_single, MapSet.new(reverted))
    }
  end

  # "This task is finished, forget it": drop the monitor so a later `:DOWN`
  # cannot be mistaken for a fresh crash, and clear the field. The second clause
  # drops a completion that arrives with nothing in flight — a stale message
  # from a task this processor has already accounted for.
  defp clear_task(%{in_flight: {_tag, _work, ref, _pid}} = state) do
    Process.demonitor(ref, [:flush])
    %{state | in_flight: nil}
  end

  defp clear_task(state), do: state

  # Route the head of `pending_ids`. Batching is checked live, per cycle,
  # so flipping the `:batch_enabled` flag at runtime takes effect without
  # restarting the processor (a production safety lever). In batch mode,
  # `force_single` ids — a batch that hit an unexpected DB error — drain
  # through the single-cmd path first, one per round, before batching
  # resumes; otherwise a normal batch round runs. When batching is off,
  # every command goes through the legacy single-cmd path.
  defp dispatch_pending(%{pending_ids: [head | rest]} = state) do
    if Config.batch_enabled?() do
      case take_forced_single(state) do
        {id, new_state} -> start_processing(new_state, id)
        :none -> dispatch_batch_or_legacy(state)
      end
    else
      start_processing(
        %{state | pending_ids: rest, force_single: MapSet.delete(state.force_single, head)},
        head
      )
    end
  end

  # Loads up to `Config.batch_size/0` commands and batches the longest contiguous
  # batchable prefix. The first non-batchable command remains at the head of
  # `pending_ids`, so it is processed singly on the next cycle before any
  # later commands. If the first command is non-batchable, process it singly
  # immediately. IDs whose commands disappeared are dropped.
  defp dispatch_batch_or_legacy(%{pending_ids: ids} = state) do
    {candidate_ids, ids_after_window} = Enum.split(ids, Config.batch_size())
    commands = Scheduling.load_commands(candidate_ids)
    {batchable_prefix, remaining_commands} = Enum.split_while(commands, &batchable?/1)
    remaining_ids = Enum.map(remaining_commands, & &1.id) ++ ids_after_window

    case {batchable_prefix, remaining_commands} do
      {[], []} ->
        send(self(), :process_next)
        {:noreply, %{state | pending_ids: ids_after_window}}

      {[], [single | rest]} ->
        pending_ids = Enum.map(rest, & &1.id) ++ ids_after_window
        start_processing(%{state | pending_ids: pending_ids}, single.id)

      {prefix, _remainder} ->
        claim_and_start_batch(%{state | pending_ids: remaining_ids}, prefix)
    end
  end

  defp batchable?(%Command{command_map: %{action: action}})
       when action in [:create_transaction, :update_transaction],
       do: true

  defp batchable?(_command), do: false

  defp start_batch_processing(
         %{batch_processor: bp, instance_id: instance_id} = state,
         commands
       ) do
    Logger.info("Processing batch of #{length(commands)} commands for instance #{instance_id}")

    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(@worker_supervisor, fn ->
        outcomes = bp.run_batch(commands)
        send(parent, {:batch_complete, outcomes})
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | in_flight: {:batch, commands, ref, pid}}}
  end

  # Claim the batch via `Scheduling.claim_batch_for_processing/3`, then run
  # it against the freshly-claimed rows. Claiming sets status → :processing,
  # bumps retry_count per legacy semantics, and stamps processor metadata,
  # so the batch failure writer's retry/dead-letter decisions read a correct
  # retry_count (the writer intentionally never bumps it itself). The claim
  # returns the claimed commands with refreshed queue items, so there's no
  # second load. Commands that raced out of a claimable state are skipped.
  defp claim_and_start_batch(state, commands) do
    case Scheduling.claim_batch_for_processing(commands, state.grant) do
      [] ->
        # Everything raced out of a claimable state — nothing to run.
        send(self(), :process_next)
        {:noreply, state}

      claimed_commands ->
        start_batch_processing(state, claimed_commands)
    end
  rescue
    Lease.LostError ->
      lease_lost(state, :claim)

    Lease.BusyError ->
      Process.send_after(self(), :process_next, Config.lease_lock_timeout_ms())
      {:noreply, %{state | pending_ids: Enum.map(commands, & &1.id) ++ state.pending_ids}}
  end

  # Revert the claimed rows to :pending under the lease and requeue only what
  # was actually reverted, flagged so the batch drains one command at a time.
  defp fall_back_to_single(state, batch) do
    run_cleanup({:revert, Enum.map(batch, & &1.id), :fallback_to_single}, state)
  end

  # If any pending id is flagged for single-cmd processing, pop the first
  # such id (removing it from both `pending_ids` and `force_single`) so it
  # can be dispatched via `start_processing/2`. Returns `:none` otherwise.
  defp take_forced_single(%{force_single: force_single, pending_ids: pending_ids} = state) do
    case Enum.find(pending_ids, &MapSet.member?(force_single, &1)) do
      nil ->
        :none

      id ->
        {id,
         %{
           state
           | pending_ids: List.delete(pending_ids, id),
             force_single: MapSet.delete(force_single, id)
         }}
    end
  end

  # One concise log line per success and per failure. Detailed audit
  # info is recorded by the writer directly into the queue rows.
  defp log_outcomes({:ok, %{successes: successes, failures: failures}}) do
    Enum.each(successes, fn %{command_id: cid, transaction_id: tid} ->
      Logger.info("Batched command #{cid} processed (transaction #{tid})")
    end)

    Enum.each(failures, fn %{command_id: cid, reason: reason} ->
      Logger.warning("Batched command #{cid} failed: #{Cleanup.failure_shape(reason)}")
    end)
  end

  defp log_outcomes({:error, reason}) do
    Logger.warning(
      "Batch run returned error (commands left in queue for retry): #{Cleanup.failure_shape(reason)}"
    )
  end

  # Spawns a supervised, unlinked Task to run the worker for a single command
  # id, monitors it, and updates state. Caller is responsible for popping the
  # id off pending_ids before calling.
  defp start_processing(
         %{worker: worker, instance_id: instance_id, grant: grant} = state,
         command_id
       ) do
    Logger.info("Processing command #{command_id} for instance #{instance_id}")

    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(@worker_supervisor, fn ->
        process_result = worker.process_command_with_id(command_id, grant)
        send(parent, {:processing_complete, command_id, process_result})
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | in_flight: {:single, command_id, ref, pid}}}
  end

  # Returns up to `limit` ids of the next in-flight commands for this
  # instance, lowest queue position first. See
  # `Scheduling.next_command_ids_query/2` for the index it drives off.
  # Before migration 5 this query started from `commands` and walked every row in
  # timestamp order — O(N²) drain behaviour.
  defp find_next_command_ids(instance_id, limit) do
    instance_id
    |> Scheduling.next_command_ids_query(limit)
    |> Repo.all()
  end
end
