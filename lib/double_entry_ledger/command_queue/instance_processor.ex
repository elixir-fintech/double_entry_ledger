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

  alias DoubleEntryLedger.{CommandQueueItem, Telemetry}
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
    name = via_tuple(instance_id)
    GenServer.start_link(__MODULE__, %{instance_id: instance_id, worker: worker}, name: name)
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
  def init(%{instance_id: instance_id, worker: worker}) do
    Logger.info("Starting command processor for instance #{instance_id}")
    Telemetry.instance_processor_start(%{instance_id: instance_id})
    # Schedule immediate processing
    send(self(), :process_next)

    {:ok,
     %{
       instance_id: instance_id,
       worker: worker,
       processing: false,
       current_command_id: nil,
       task_ref: nil,
       pending_ids: []
     }}
  end

  @impl true
  def handle_info(:process_next, %{processing: true} = state) do
    # We're already processing something, ignore
    {:noreply, state}
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

  defp processor_name do
    prefix =
      Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
        "command_queue"

    "#{prefix}_#{node()}_#{System.unique_integer([:positive])}"
  end
end
