defmodule DoubleEntryLedger.CommandQueue.Supervisor do
  @moduledoc """
  Supervises the command queue system components.

  Children, in start order:

    * `CommandQueue.Registry` - unique-keyed registry of running processors.
    * `CommandQueue.AcquireSupervisor` - a `Task.Supervisor` for the lease
      acquisition tasks the `InstanceMonitor` starts, capped at
      `DoubleEntryLedger.CommandQueue.Config.max_concurrent_acquisitions/0` children.
    * `CommandQueue.WorkerSupervisor` - a `Task.Supervisor` for the worker tasks
      (single command and batch) an `InstanceProcessor` runs. The tasks stay
      unlinked from the processor that started them and are tracked by monitor.
    * `CommandQueue.InstanceSupervisor` - a `DynamicSupervisor` holding one
      `InstanceProcessor` per leased ledger, capped at
      `DoubleEntryLedger.CommandQueue.Config.max_leases_per_node/0` children.
    * `CommandQueue.InstanceMonitor` - discovers work and starts processors.

  That order matters on the way down. Children terminate in reverse start order,
  so `WorkerSupervisor` outlives the processors, and each processor gets to kill
  its own task, wait for it, and release its lease before the task supervisor
  goes away. Reversing the two would kill the tasks first, turning shutdown into
  a round of crash-retry writes.

  `AcquireSupervisor` is placed for the same reason, and deliberately NOT next
  to `WorkerSupervisor`'s twin. An acquisition task holds an acquired lease
  while it waits for the monitor's `{:start_result, _}`, and the only thing
  that releases that lease is the task itself: on the monitor's `:DOWN` it
  calls `Lease.release(grant, :monitor_down)`. So the tasks must outlive the
  monitor, which is why `AcquireSupervisor` is started before it; had it been
  started after, shutdown would kill every waiting task first, stranding each
  acquired lease until its TTL expired, and a monitor still handling a poll
  would dispatch into a dead task supervisor.

  Placing it first among the workers rather than last is best effort on top of
  that, not a guarantee. A waiting task gets to release only if it observes the
  monitor's `:DOWN` before `AcquireSupervisor` reaches it, and it does not trap
  exits: the window is however long the children between them take to
  terminate, which is the processors' shutdown when any are running and
  essentially nothing when none are. A task killed inside that window leaves
  its lease to expire by TTL, which is the designed backstop for every
  unreleased lease (see `CommandQueue.Lease`), so the ordering buys a common
  case, not correctness.

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
    # Boot-time diagnostic, once per queue start. Deliberately not inside
    # `validate!/0`, which also runs in every `InstanceProcessor.init/1`.
    Config.warn_stale_config()

    children = [
      {Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry},
      # Must stay before InstanceMonitor, and as early as is useful; see the
      # moduledoc on shutdown order.
      {Task.Supervisor,
       name: DoubleEntryLedger.CommandQueue.AcquireSupervisor,
       max_children: Config.max_concurrent_acquisitions()},
      # Must stay before InstanceSupervisor; see the moduledoc on shutdown order.
      {Task.Supervisor, name: DoubleEntryLedger.CommandQueue.WorkerSupervisor},
      # max_children is the durable lease cap: each processor holds one lease,
      # and unlike the monitor's slot arithmetic it survives a monitor restart
      # (R14.1). :infinity passes through unchanged.
      {DynamicSupervisor,
       name: DoubleEntryLedger.CommandQueue.InstanceSupervisor,
       strategy: :one_for_one,
       max_children: Config.max_leases_per_node()},
      {DoubleEntryLedger.CommandQueue.InstanceMonitor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
