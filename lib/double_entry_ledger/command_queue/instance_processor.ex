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

  alias DoubleEntryLedger.{Repo, Command}
  alias DoubleEntryLedger.Workers.CommandWorker
  import Ecto.Query

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

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
    name = via_tuple(instance_id)
    GenServer.start_link(__MODULE__, %{instance_id: instance_id}, name: name)
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
  def init(%{instance_id: instance_id}) do
    Logger.info("Starting command processor for instance #{instance_id}")
    # Schedule immediate processing
    send(self(), :process_next)
    {:ok, %{instance_id: instance_id, processing: false}}
  end

  @impl true
  def handle_info(:process_next, %{processing: true} = state) do
    # We're already processing something, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_next, %{instance_id: instance_id} = state) do
    case find_next_command(instance_id) do
      nil ->
        # No more commands to process, terminate
        Logger.info("No more commands to process for instance #{instance_id}, shutting down")
        {:stop, :normal, state}

      command ->
        # Start processing the command
        new_state = %{state | processing: true}

        # Process command in a separate task to not block the GenServer
        Logger.info("Processing command #{command.id} for instance #{instance_id}")

        parent = self()

        Task.start(fn ->
          process_result = CommandWorker.process_command_with_id(command.id, processor_name())
          send(parent, {:processing_complete, command.id, process_result})
        end)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:processing_complete, command_id, result}, state) do
    case result do
      {:ok, _, _} ->
        Logger.info("Successfully processed command #{command_id}")

      {:error, reason} ->
        Logger.warning("Failed to process command #{command_id}: #{inspect(reason)}")
        # Note: the error is already recorded in the command by CommandWorker.process_command_with_id
    end

    # Command processing completed, check for more commands
    new_state = %{state | processing: false}
    send(self(), :process_next)
    {:noreply, new_state}
  end

  defp find_next_command(instance_id) do
    now = DateTime.utc_now()

    # Find a command for this instance that's ready to be processed
    from(e in Command,
      join: eqi in assoc(e, :command_queue_item),
      prefix: ^@schema_prefix,
      where:
        eqi.status in [:pending, :occ_timeout, :failed] and
          e.instance_id == ^instance_id and
          (is_nil(eqi.next_retry_after) or eqi.next_retry_after <= ^now),
      order_by: [asc: e.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp processor_name do
    prefix =
      Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
        "command_queue"

    "#{prefix}_#{node()}_#{System.unique_integer([:positive])}"
  end
end
