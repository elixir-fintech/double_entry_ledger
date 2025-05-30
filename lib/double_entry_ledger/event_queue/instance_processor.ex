defmodule DoubleEntryLedger.EventQueue.InstanceProcessor do
  @moduledoc """
  Handles processing of events for a specific event queue instance.

  The `InstanceProcessor` is responsible for fetching, processing, and updating the status
  of events belonging to a single event queue instance. It is started dynamically by the
  `InstanceMonitor` when there are events to process for a given instance.

  ## Responsibilities

    * Fetch pending, failed, or timed-out events for the assigned instance.
    * Process each event and update its status in the database.
    * Handle retries and error cases according to event queue logic.
    * Ensure only one processor runs per instance at a time (enforced via Registry).

  This module is typically supervised under the `InstanceSupervisor` as a dynamic child.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.{EventWorker, Repo, Event}
  import Ecto.Query

  # Client API

  @doc """
  Starts an instance processor for the specified instance.

  ## Parameters
    - `opts` - Keyword list of options where:
      - `:instance_id` - Required UUID of the instance to process events for

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
    {:via, Registry, {DoubleEntryLedger.EventQueue.Registry, instance_id}}
  end

  # Server Callbacks

  @impl true
  def init(%{instance_id: instance_id}) do
    Logger.info("Starting event processor for instance #{instance_id}")
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
    case find_next_event(instance_id) do
      nil ->
        # No more events to process, terminate
        Logger.info("No more events to process for instance #{instance_id}, shutting down")
        {:stop, :normal, state}

      event ->
        # Start processing the event
        new_state = %{state | processing: true}

        # Process event in a separate task to not block the GenServer
        Logger.info("Processing event #{event.id} for instance #{instance_id}")

        Task.start(fn ->
          process_result = EventWorker.process_event_with_id(event.id, processor_name())
          send(self(), {:processing_complete, event.id, process_result})
        end)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:processing_complete, event_id, result}, state) do
    case result do
      {:ok, _, _} ->
        Logger.info("Successfully processed event #{event_id}")

      {:error, reason} ->
        Logger.warning("Failed to process event #{event_id}: #{inspect(reason)}")
        # Note: the error is already recorded in the event by EventWorker.process_event_with_id
    end

    # Event processing completed, check for more events
    new_state = %{state | processing: false}
    send(self(), :process_next)
    {:noreply, new_state}
  end

  defp find_next_event(instance_id) do
    now = DateTime.utc_now()

    # Find an event for this instance that's ready to be processed
    from(e in Event,
      join: eqi in assoc(e, :event_queue_item),
      prefix: "double_entry_ledger",
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
      Application.get_env(:double_entry_ledger, :event_queue, [])[:processor_name] ||
        "event_queue"

    "#{prefix}_#{node()}_#{System.unique_integer([:positive])}"
  end
end
