defmodule DoubleEntryLedger.CommandQueue.InstanceProcessor do
  @moduledoc """
  Handles processing of commands for a specific instance.

  The `InstanceProcessor` is responsible for fetching, processing, and updating the status
  of commands belonging to a single instance. It is started dynamically by the
  `InstanceMonitor` when there are queued commands to process.

  ## Responsibilities

    * Fetch pending, failed, or timed-out commands for the assigned instance.
    * Process each command and update its status in the database.
    * Handle retries and error cases according to command queue logic.
    * Ensure only one processor runs per instance at a time (enforced via Registry).
    * Buffer command ids in memory (`:pending_fetch_limit`, default 64) and drain that
      buffer before hitting the database again.
    * When `:batch_enabled` is set, process up to `:batch_size` (default 8) commands per
      batch; a batch that hits an unexpected database error is reverted to `:pending` and
      its commands are flagged `force_single` so they drain one at a time.

  This module is typically supervised under the `InstanceSupervisor` as a dynamic child.
  """
  use GenServer, restart: :temporary
  require Logger

  alias DoubleEntryLedger.{BatchProcessor, Command, Telemetry}
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker
  import Ecto.Query

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()

  # Client API

  @doc """
  Starts an instance processor for the specified instance.

  ## Parameters
    - `opts` - Keyword list of options where:
      - `:instance_id` - Required UUID of the instance to process commands for

  ## Returns
    - `{:ok, pid}` - Successfully started the processor
    - `{:error, reason}` - Failed to start the processor
  """
  def start_link(opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    worker = Keyword.get(opts, :worker, CommandWorker)
    batch_processor = Keyword.get(opts, :batch_processor, BatchProcessor)
    name = via_tuple(instance_id)

    GenServer.start_link(
      __MODULE__,
      %{instance_id: instance_id, worker: worker, batch_processor: batch_processor},
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
  def via_tuple(instance_id) do
    {:via, Registry, {DoubleEntryLedger.CommandQueue.Registry, instance_id}}
  end

  # Server Callbacks

  @impl true
  def init(%{instance_id: instance_id, worker: worker, batch_processor: batch_processor}) do
    Logger.info("Starting command processor for instance #{instance_id}")
    Telemetry.instance_processor_start(%{instance_id: instance_id})

    # Schedule immediate processing
    send(self(), :process_next)

    {:ok,
     %{
       instance_id: instance_id,
       worker: worker,
       batch_processor: batch_processor,
       processing: false,
       current_command_id: nil,
       current_processor_id: nil,
       task_ref: nil,
       pending_ids: [],
       current_batch: nil,
       # Command ids that must be processed one-at-a-time via the
       # single-cmd path instead of being re-batched. Populated when a
       # batch write hits an unexpected DB error and we fall back to
       # per-command processing (see the {:batch_complete, {:error, _}}
       # handler). Always a subset of `pending_ids`.
       force_single: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:process_next, %{processing: true} = state) do
    # We're already processing something, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_next, %{pending_ids: [_ | _]} = state) do
    dispatch_pending(state)
  end

  @impl true
  def handle_info(:process_next, %{pending_ids: []} = state) do
    # Drain from the in-memory buffer first; only hit the DB to refill
    # when it's empty. This amortizes the find_next SELECT cost across
    # `pending_fetch_limit/0` commands per round-trip.
    case find_next_command_ids(state.instance_id, pending_fetch_limit()) do
      [] ->
        Logger.info(
          "No more commands to process for instance #{state.instance_id}, shutting down"
        )

        Telemetry.instance_processor_stop(%{instance_id: state.instance_id})
        {:stop, :normal, state}

      ids ->
        dispatch_pending(%{state | pending_ids: ids})
    end
  end

  @impl true
  def handle_info({:processing_complete, command_id, result}, %{task_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])

    case result do
      {:ok, _, _} ->
        Logger.info("Successfully processed command #{command_id}")

      {:error, reason} ->
        Logger.warning("Failed to process command #{command_id}: #{inspect(reason)}")

        # Note: the error is already recorded in the command by CommandWorker.process_command_with_id
    end

    # Command processing completed, check for more commands
    send(self(), :process_next)

    {:noreply,
     %{
       state
       | processing: false,
         current_command_id: nil,
         current_processor_id: nil,
         task_ref: nil
     }}
  end

  @impl true
  def handle_info({:batch_complete, {:ok, _} = outcomes}, %{task_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    log_outcomes(outcomes)

    send(self(), :process_next)
    {:noreply, %{state | processing: false, task_ref: nil, current_batch: nil}}
  end

  # Unexpected (non-stale) DB error from the batched write: the whole
  # transaction rolled back, so nothing in the batch was persisted. Per
  # the plan (§8.3) fall back to per-command processing for this batch so
  # a single offending command is isolated instead of poisoning the whole
  # batch forever. Revert the claimed rows to :pending (retry_count set at
  # claim is preserved, and re-claiming from :pending won't double-bump),
  # then flag them `force_single` and re-queue them at the front.
  @impl true
  def handle_info(
        {:batch_complete, {:error, _reason} = outcomes},
        %{task_ref: ref, current_batch: batch} = state
      ) do
    if ref, do: Process.demonitor(ref, [:flush])
    log_outcomes(outcomes)

    fall_back_to_single(state, batch || [])
  end

  # Batch task crashed — fall back to the single-command path so one
  # deterministically crashing command cannot consume the retry budget of
  # otherwise healthy neighbours.
  # Must come BEFORE the per-command :DOWN clause so pattern-matching
  # picks this up when current_batch is set.
  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task_ref: ref, current_batch: batch, instance_id: instance_id} = state
      )
      when is_list(batch) do
    Logger.error(
      "Batch task crashed for instance #{instance_id} (#{length(batch)} cmds): #{inspect(reason)}"
    )

    fall_back_to_single(state, batch)
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{
          task_ref: ref,
          current_command_id: command_id,
          current_processor_id: processor_id,
          instance_id: instance_id
        } = state
      ) do
    Logger.error(
      "Command task crashed for command #{command_id} on instance #{instance_id}: #{inspect(reason)}"
    )

    schedule_retry_for_crashed_command(command_id, processor_id, reason)

    send(self(), :process_next)

    {:noreply,
     %{
       state
       | processing: false,
         current_command_id: nil,
         current_processor_id: nil,
         task_ref: nil
     }}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # :DOWN from an unrelated or already-handled process, ignore
    {:noreply, state}
  end

  # Route the head of `pending_ids`. Batching is checked live, per cycle,
  # so flipping the `:batch_enabled` flag at runtime takes effect without
  # restarting the processor (a production safety lever). In batch mode,
  # `force_single` ids — a batch that hit an unexpected DB error — drain
  # through the single-cmd path first, one per round, before batching
  # resumes; otherwise a normal batch round runs. When batching is off,
  # every command goes through the legacy single-cmd path.
  defp dispatch_pending(%{pending_ids: [head | rest]} = state) do
    if batch_enabled?() do
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

  # Loads up to `batch_size/0` commands and batches the longest contiguous
  # batchable prefix. The first non-batchable command remains at the head of
  # `pending_ids`, so it is processed singly on the next cycle before any
  # later commands. If the first command is non-batchable, process it singly
  # immediately. IDs whose commands disappeared are dropped.
  defp dispatch_batch_or_legacy(%{pending_ids: ids} = state) do
    {candidate_ids, ids_after_window} = Enum.split(ids, batch_size())
    commands = load_commands(candidate_ids)
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

  # Loads commands with their command_queue_item preloaded, preserving
  # the order of `ids`. Commands that no longer exist are omitted.
  defp load_commands(ids) do
    rows =
      from(c in Command,
        prefix: ^@schema_prefix,
        where: c.id in ^ids,
        preload: [:command_queue_item]
      )
      |> Repo.all()

    by_id = Map.new(rows, &{&1.id, &1})
    Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)
  end

  defp start_batch_processing(
         %{batch_processor: bp, instance_id: instance_id} = state,
         commands
       ) do
    Logger.info("Processing batch of #{length(commands)} commands for instance #{instance_id}")

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        outcomes = bp.run_batch(commands)
        send(parent, {:batch_complete, outcomes})
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | processing: true, task_ref: ref, current_batch: commands}}
  end

  # Claim the batch via `Scheduling.claim_batch_for_processing/3`, then run
  # it against the freshly-claimed rows. Claiming sets status → :processing,
  # bumps retry_count per legacy semantics, and stamps processor metadata,
  # so the batch failure writer's retry/dead-letter decisions read a correct
  # retry_count (the writer intentionally never bumps it itself). The claim
  # returns the claimed commands with refreshed queue items, so there's no
  # second load. Commands that raced out of a claimable state are skipped.
  defp claim_and_start_batch(state, commands) do
    case Scheduling.claim_batch_for_processing(commands, processor_name()) do
      [] ->
        # Everything raced out of a claimable state — nothing to run.
        send(self(), :process_next)
        {:noreply, state}

      claimed_commands ->
        start_batch_processing(state, claimed_commands)
    end
  end

  # Revert claimed rows back to :pending so they can be re-processed via
  # the single-cmd path. The claim's processor_version fences each write,
  # so rows already completed or transferred to another owner are skipped;
  # retry_count is intentionally left as-is (set at claim time) so the
  # subsequent single-cmd re-claim from :pending won't double-count it.
  defp revert_batch_to_pending([]), do: []

  defp revert_batch_to_pending(commands) do
    Enum.flat_map(commands, fn command ->
      try do
        command
        |> Scheduling.build_revert_to_pending(nil)
        |> Repo.update!()

        [command.id]
      rescue
        Ecto.StaleEntryError -> []
      end
    end)
  end

  defp fall_back_to_single(state, batch) do
    reverted_ids = revert_batch_to_pending(batch)
    send(self(), :process_next)

    {:noreply,
     %{
       state
       | processing: false,
         task_ref: nil,
         current_batch: nil,
         pending_ids: reverted_ids ++ state.pending_ids,
         force_single: MapSet.union(state.force_single, MapSet.new(reverted_ids))
     }}
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
      Logger.warning("Batched command #{cid} failed: #{inspect(reason)}")
    end)
  end

  defp log_outcomes({:error, reason}) do
    Logger.warning(
      "Batch run returned error (commands left in queue for retry): #{inspect(reason)}"
    )
  end

  defp schedule_retry_for_crashed_command(command_id, processor_id, reason) do
    case CommandStore.get_by_id(command_id) do
      nil ->
        Logger.error("Could not find command #{command_id} to schedule retry after crash")

      %{command_queue_item: %{status: :processing, processor_id: ^processor_id}} = command ->
        try do
          Scheduling.schedule_retry_with_reason(
            command,
            "Task crashed: #{inspect(reason)}",
            :failed
          )
        rescue
          Ecto.StaleEntryError ->
            log_ownership_changed(command_id)
        end

      _command ->
        log_ownership_changed(command_id)
    end
  end

  defp log_ownership_changed(command_id) do
    Logger.warning("Skipped crash retry for command #{command_id} because ownership changed")
  end

  # Spawns a Task to run the worker for a single command id, monitors it,
  # and updates state. Caller is responsible for popping the id off
  # pending_ids before calling.
  defp start_processing(%{worker: worker, instance_id: instance_id} = state, command_id) do
    Logger.info("Processing command #{command_id} for instance #{instance_id}")

    parent = self()
    processor_id = processor_name()

    {:ok, pid} =
      Task.start(fn ->
        process_result = worker.process_command_with_id(command_id, processor_id)
        send(parent, {:processing_complete, command_id, process_result})
      end)

    ref = Process.monitor(pid)

    {:noreply,
     %{
       state
       | processing: true,
         current_command_id: command_id,
         current_processor_id: processor_id,
         task_ref: ref
     }}
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

  defp pending_fetch_limit do
    Application.get_env(:double_entry_ledger, :command_queue, [])[:pending_fetch_limit] || 64
  end

  defp batch_enabled? do
    Application.get_env(:double_entry_ledger, :batch_enabled, false)
  end

  defp batch_size do
    configured_size =
      Application.get_env(:double_entry_ledger, :batch_size) ||
        Application.get_env(:double_entry_ledger, :command_queue, [])[:batch_size] ||
        8

    normalize_batch_size(configured_size)
  end

  defp normalize_batch_size(size) when is_integer(size), do: max(size, 1)

  defp normalize_batch_size(size) do
    raise ArgumentError, "expected :batch_size to be an integer, got: #{inspect(size)}"
  end

  defp processor_name do
    prefix =
      Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
        "command_queue"

    "#{prefix}_#{node()}_#{System.unique_integer([:positive])}"
  end
end
