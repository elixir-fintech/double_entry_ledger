defmodule DoubleEntryLedger.CommandQueue.InstanceMonitor do
  @moduledoc """
  Monitors the command queue for pending commands and ensures processors are started as needed.

  ## Overview

  The `InstanceMonitor` is a GenServer responsible for periodically scanning the database
  for instances that have commands requiring processing. For each such instance,
  it ensures that an `InstanceProcessor` is running to handle those commands.

  ## Responsibilities

    * Periodically poll the database for instances with pending, failed, or timed-out commands.
    * For each instance with processable commands, ensure an `InstanceProcessor` is started.
    * Avoid starting duplicate processors for the same instance by checking the Registry.
    * Use application configuration for poll interval (`:poll_interval` in `:command_queue` config).

  ## Configuration

  The poll interval can be set in your application config:

      config :double_entry_ledger, :command_queue, poll_interval: 5_000

  The default poll interval is 5,000 milliseconds (5 seconds) if not specified.

  ## Process Supervision

  This module is intended to be supervised as part of the command queue supervision tree.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  alias DoubleEntryLedger.CommandQueue.{InstanceProcessor, Scheduling}

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
    config = Application.get_env(:double_entry_ledger, :command_queue, [])
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
    # Find instances with processable commands
    instances_with_commands = find_instances_with_commands()

    # Start processors for each instance
    Enum.each(instances_with_commands, &ensure_processor/1)
  end

  defp find_instances_with_commands do
    # Distinct instance IDs with processable commands, evaluated on the
    # database clock.
    Repo.all(Scheduling.instances_with_processable_commands_query())
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
