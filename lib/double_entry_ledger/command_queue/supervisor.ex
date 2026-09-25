defmodule DoubleEntryLedger.CommandQueue.Supervisor do
  @moduledoc """
  Supervises the command queue system components.

  Children, in start order:

    * `CommandQueue.Registry` - unique-keyed registry of running processors.
    * `CommandQueue.WorkerSupervisor` - a `Task.Supervisor` for the worker tasks
      (single command and batch) an `InstanceProcessor` runs. The tasks stay
      unlinked from the processor that started them and are tracked by monitor.
    * `CommandQueue.InstanceSupervisor` - a `DynamicSupervisor` holding one
      `InstanceProcessor` per leased ledger.
    * `CommandQueue.InstanceMonitor` - discovers work and starts processors.

  That order matters on the way down. Children terminate in reverse start order,
  so `WorkerSupervisor` outlives the processors, and each processor gets to kill
  its own task, wait for it, and release its lease before the task supervisor
  goes away. Reversing the two would kill the tasks first, turning shutdown into
  a round of crash-retry writes.

  The strategy is `:one_for_one`, so a child that terminates is restarted alone.
  """

  use Supervisor

  alias DoubleEntryLedger.CommandQueue.Config

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
    Config.validate!()

    children = [
      {Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry},
      # Must stay before InstanceSupervisor; see the moduledoc on shutdown order.
      {Task.Supervisor, name: DoubleEntryLedger.CommandQueue.WorkerSupervisor},
      {DynamicSupervisor,
       name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one},
      {DoubleEntryLedger.CommandQueue.InstanceMonitor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
