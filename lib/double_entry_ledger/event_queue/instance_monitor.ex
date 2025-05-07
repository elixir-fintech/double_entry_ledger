defmodule DoubleEntryLedger.EventQueue.InstanceMonitor do
  @moduledoc """
  Monitors for instances with pending events and starts processors as needed.

  This module periodically checks for instances that have events needing processing
  and ensures an instance processor is running for each of them.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.{Repo, Event}
  alias DoubleEntryLedger.EventQueue.InstanceProcessor

  import Ecto.Query

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    config = Application.get_env(:double_entry_ledger, :event_queue, [])
    poll_interval = Keyword.get(config, :poll_interval, 5_000)

    schedule_poll(poll_interval)
    {:ok, %{poll_interval: poll_interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    monitor_instances()
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  # Private functions

  defp monitor_instances do
    # Find instances with processable events
    instances_with_events = find_instances_with_events()

    # Start processors for each instance
    Enum.each(instances_with_events, &ensure_processor/1)
  end

  defp find_instances_with_events do
    now = DateTime.utc_now()

    # Find distinct instance IDs with pending events
    from(e in Event,
      where:
        e.status in [:pending, :occ_timeout, :failed] and
          (is_nil(e.next_retry_after) or e.next_retry_after <= ^now),
      select: e.instance_id,
      distinct: true
    )
    |> Repo.all()
  end

  defp ensure_processor(instance_id) do
    # Check if processor already exists
    case Registry.lookup(DoubleEntryLedger.EventQueue.Registry, instance_id) do
      [] ->
        # No processor running, start one
        Logger.info("Starting new processor for instance #{instance_id}")

        DynamicSupervisor.start_child(
          DoubleEntryLedger.EventQueue.InstanceSupervisor,
          {InstanceProcessor, [instance_id: instance_id]}
        )

      [{pid, _}] ->
        # Processor already running
        Logger.debug("Processor already running for instance #{instance_id}: #{inspect(pid)}")
        :ok
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
