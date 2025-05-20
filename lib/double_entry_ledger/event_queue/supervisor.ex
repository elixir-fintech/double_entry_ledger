defmodule DoubleEntryLedger.EventQueue.Supervisor do
  @moduledoc """
  Supervises the event queue system components.

  This supervisor is responsible for starting and monitoring the following child processes:

    * `Registry` - A unique-keyed process registry for event queue instances.
    * `DynamicSupervisor` - Supervises dynamically started event queue instances.
    * `DoubleEntryLedger.EventQueue.InstanceMonitor` - Monitors and manages the lifecycle of event queue instances.

  The supervisor uses the `:one_for_one` strategy, so if a child process terminates,
  only that process is restarted.
  """

  use Supervisor

  @doc """
  Starts the EventQueue supervisor.

  ## Parameters

    - `init_arg`: Initialization argument (not used).

  ## Returns

    - `{:ok, pid}` on success.
    - `{:error, reason}` on failure.
  """
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  @doc false
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: DoubleEntryLedger.EventQueue.Registry},
      {DynamicSupervisor,
       name: DoubleEntryLedger.EventQueue.InstanceSupervisor, strategy: :one_for_one},
      {DoubleEntryLedger.EventQueue.InstanceMonitor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
