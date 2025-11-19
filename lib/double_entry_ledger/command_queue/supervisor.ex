defmodule DoubleEntryLedger.CommandQueue.Supervisor do
  @moduledoc """
  Supervises the command queue system components.

  This supervisor is responsible for starting and monitoring the following child processes:

    * `Registry` - A unique-keyed process registry for command queue instances.
    * `DynamicSupervisor` - Supervises dynamically started command queue processors.
    * `DoubleEntryLedger.CommandQueue.InstanceMonitor` - Monitors and manages the lifecycle of command queue instances.

  The supervisor uses the `:one_for_one` strategy, so if a child process terminates,
  only that process is restarted.
  """

  use Supervisor

  @doc """
  Starts the command queue supervisor.

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
      {Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry},
      {DynamicSupervisor,
       name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one},
      {DoubleEntryLedger.CommandQueue.InstanceMonitor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
