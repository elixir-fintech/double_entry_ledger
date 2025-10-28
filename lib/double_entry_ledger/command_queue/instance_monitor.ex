defmodule DoubleEntryLedger.CommandQueue.InstanceMonitor do
  @moduledoc """
  Monitors event queue instances for pending events and ensures processors are started as needed.

  ## Overview

  The `InstanceMonitor` is a GenServer responsible for periodically scanning the database
  for event queue instances that have events requiring processing. For each such instance,
  it ensures that an `InstanceProcessor` is running to handle the events.

  ## Responsibilities

    * Periodically poll the database for instances with pending, failed, or timed-out events.
    * For each instance with processable events, ensure an `InstanceProcessor` is started.
    * Avoid starting duplicate processors for the same instance by checking the Registry.
    * Use application configuration for poll interval (`:poll_interval` in `:event_queue` config).

  ## Configuration

  The poll interval can be set in your application config:

      config :double_entry_ledger, :event_queue, poll_interval: 5_000

  The default poll interval is 5,000 milliseconds (5 seconds) if not specified.

  ## Process Supervision

  This module is intended to be supervised as part of the event queue supervision tree.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.{Repo, Command, CommandQueueItem}

  alias DoubleEntryLedger.CommandQueue.InstanceProcessor

  import Ecto.Query

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  # Client API

  @doc """
  Starts the InstanceMonitor GenServer.

  This function is typically called by the supervisor and does not need to be called directly.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  @doc false
  def init(_) do
    config = Application.get_env(:double_entry_ledger, :event_queue, [])
    poll_interval = Keyword.get(config, :poll_interval, 5_000)

    schedule_poll(poll_interval)
    {:ok, %{poll_interval: poll_interval}}
  end

  @impl true
  @doc false
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
    from(e in Command,
      join: eqi in CommandQueueItem,
      prefix: ^@schema_prefix,
      on: e.id == eqi.event_id,
      where:
        eqi.status in [:pending, :occ_timeout, :failed] and
          (is_nil(eqi.next_retry_after) or eqi.next_retry_after <= ^now),
      select: e.instance_id,
      distinct: true
    )
    |> Repo.all()
  end

  defp ensure_processor(instance_id) do
    # Check if processor already exists
    case Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance_id) do
      [] ->
        # No processor running, start one
        Logger.info("Starting new processor for instance #{instance_id}")

        DynamicSupervisor.start_child(
          DoubleEntryLedger.CommandQueue.InstanceSupervisor,
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
