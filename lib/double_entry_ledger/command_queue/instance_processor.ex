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

  This module is typically supervised under the `InstanceSupervisor` as a dynamic child.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.{BatchProcessor, Command, CommandQueueItem, Telemetry}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Stores.CommandStore
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

    # Read once at init — flag changes require a restart to take effect.
    batch_enabled = Application.get_env(:double_entry_ledger, :batch_enabled, false)

    # Schedule immediate processing
    send(self(), :process_next)

    {:ok,
     %{
       instance_id: instance_id,
       worker: worker,
       batch_processor: batch_processor,
       batch_enabled: batch_enabled,
       processing: false,
       current_command_id: nil,
       task_ref: nil,
       pending_ids: [],
       current_batch: nil
     }}
  end

  @impl true
  def handle_info(:process_next, %{processing: true} = state) do
    # We're already processing something, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_next, %{pending_ids: [_ | _], batch_enabled: true} = state) do
    # Batch mode: try to take up to batch_size ids and dispatch them as
    # a single BatchProcessor.run_batch/2 call, but only when ALL the
    # claimed commands are :create_transaction. Mixed batches fall back
    # to processing one command at a time through the legacy path; the
    # next round may then re-evaluate as all-create and batch.
    dispatch_batch_or_legacy(state)
  end

  @impl true
  def handle_info(:process_next, %{pending_ids: [head | rest]} = state) do
    # Drain from the in-memory buffer first; only hit the DB to refill
    # when it's empty. This amortizes the find_next SELECT cost across
    # `claim_batch_size/0` commands per round-trip.
    start_processing(%{state | pending_ids: rest}, head)
  end

  @impl true
  def handle_info(:process_next, %{pending_ids: []} = state) do
    case find_next_command_ids(state.instance_id, claim_batch_size()) do
      [] ->
        Logger.info(
          "No more commands to process for instance #{state.instance_id}, shutting down"
        )

        Telemetry.instance_processor_stop(%{instance_id: state.instance_id})
        {:stop, :normal, state}

      ids when state.batch_enabled ->
        # Re-enter via the batch dispatcher; it will split off up to
        # batch_size, decide all-create vs mixed, and act.
        dispatch_batch_or_legacy(%{state | pending_ids: ids})

      [head | rest] ->
        start_processing(%{state | pending_ids: rest}, head)
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
    {:noreply, %{state | processing: false, current_command_id: nil, task_ref: nil}}
  end

  @impl true
  def handle_info({:batch_complete, outcomes}, %{task_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    log_outcomes(outcomes)

    send(self(), :process_next)
    {:noreply, %{state | processing: false, task_ref: nil, current_batch: nil}}
  end

  # Batch task crashed — mark every command in the batch for retry.
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

    Enum.each(batch, fn cmd_id ->
      schedule_retry_for_crashed_command(cmd_id, {:batch_crashed, reason})
    end)

    send(self(), :process_next)
    {:noreply, %{state | processing: false, task_ref: nil, current_batch: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task_ref: ref, current_command_id: command_id, instance_id: instance_id} = state
      ) do
    Logger.error(
      "Command task crashed for command #{command_id} on instance #{instance_id}: #{inspect(reason)}"
    )

    schedule_retry_for_crashed_command(command_id, reason)

    send(self(), :process_next)
    {:noreply, %{state | processing: false, current_command_id: nil, task_ref: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # :DOWN from an unrelated or already-handled process, ignore
    {:noreply, state}
  end

  # Decides whether to batch the next round or fall back to the per-cmd
  # path. Loads up to `batch_size/0` commands (preloading queue items),
  # and:
  #
  #   * if every command's action is :create_transaction → spawn a Task
  #     that calls `state.batch_processor.run_batch/2`.
  #   * if any non-create action is present → fall back to processing a
  #     single command via the legacy single-cmd Task path. Remaining
  #     ids stay in pending_ids and the next round may batch them.
  #   * if the load returns nothing (e.g. ids vanished from the DB) →
  #     drop them and trigger another :process_next cycle.
  defp dispatch_batch_or_legacy(%{pending_ids: ids} = state) do
    {batch_ids, rest_after_batch} = Enum.split(ids, batch_size())
    commands = load_commands(batch_ids)

    cond do
      commands == [] ->
        # IDs disappeared from the DB (race or already processed). Drop
        # them and continue.
        send(self(), :process_next)
        {:noreply, %{state | pending_ids: rest_after_batch}}

      all_create_transaction?(commands) ->
        start_batch_processing(%{state | pending_ids: rest_after_batch}, commands, batch_ids)

      true ->
        # Mixed batch: process exactly one command via the legacy path.
        # The remaining ids stay pending; on the next cycle they'll be
        # re-evaluated and may now form an all-create round.
        [head | rest] = ids
        start_processing(%{state | pending_ids: rest}, head)
    end
  end

  defp all_create_transaction?(commands) do
    Enum.all?(commands, fn
      %Command{command_map: %{action: :create_transaction}} -> true
      _ -> false
    end)
  end

  # Loads commands by id with command_queue_item preloaded, in claim
  # order (matching the order of `ids`). One round-trip.
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
         commands,
         batch_ids
       ) do
    Logger.info("Processing batch of #{length(commands)} commands for instance #{instance_id}")

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        outcomes = bp.run_batch(commands)
        send(parent, {:batch_complete, outcomes})
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | processing: true, task_ref: ref, current_batch: batch_ids}}
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

  defp schedule_retry_for_crashed_command(command_id, reason) do
    case CommandStore.get_by_id(command_id) do
      nil ->
        Logger.error("Could not find command #{command_id} to schedule retry after crash")

      command ->
        Scheduling.build_schedule_retry_with_reason(
          command,
          "Task crashed: #{inspect(reason)}",
          :failed
        )
        |> Repo.update()
    end
  end

  # Spawns a Task to run the worker for a single command id, monitors it,
  # and updates state. Caller is responsible for popping the id off
  # pending_ids before calling.
  defp start_processing(%{worker: worker, instance_id: instance_id} = state, command_id) do
    Logger.info("Processing command #{command_id} for instance #{instance_id}")

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        process_result = worker.process_command_with_id(command_id, processor_name())
        send(parent, {:processing_complete, command_id, process_result})
      end)

    ref = Process.monitor(pid)

    {:noreply, %{state | processing: true, current_command_id: command_id, task_ref: ref}}
  end

  # Returns up to `limit` ids of the next in-flight commands for this
  # instance, oldest first. Drives off the partial index
  # `idx_command_queue_items_in_flight` added in migration v6:
  # (instance_id, inserted_at) WHERE status IN ('pending', 'occ_timeout',
  # 'failed'). Before v6 this query started from `commands` and walked
  # every row in inserted_at order — O(N²) drain behaviour.
  defp find_next_command_ids(instance_id, limit) do
    now = DateTime.utc_now()

    from(eqi in CommandQueueItem,
      prefix: ^@schema_prefix,
      where:
        eqi.instance_id == ^instance_id and
          eqi.status in [:pending, :occ_timeout, :failed] and
          (is_nil(eqi.next_retry_after) or eqi.next_retry_after <= ^now),
      order_by: [asc: eqi.inserted_at],
      limit: ^limit,
      select: eqi.command_id
    )
    |> Repo.all()
  end

  defp claim_batch_size do
    Application.get_env(:double_entry_ledger, :command_queue, [])[:claim_batch_size] || 50
  end

  defp batch_size do
    Application.get_env(:double_entry_ledger, :command_queue, [])[:batch_size] || 8
  end

  defp processor_name do
    prefix =
      Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
        "command_queue"

    "#{prefix}_#{node()}_#{System.unique_integer([:positive])}"
  end
end
