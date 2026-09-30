defmodule DoubleEntryLedger.CommandQueue.InstanceMonitor do
  @moduledoc """
  Acquires ledger leases and starts one `InstanceProcessor` per lease.

  ## Overview

  The `InstanceMonitor` is a GenServer that periodically asks a
  `CommandQueue.Coordinator` which ledgers this node should attempt to own,
  acquires a lease for each one in its own task, and starts a processor with
  the resulting grant.

  ## The coordinator / lease split (design §9)

  Two different questions, answered by two different modules:

    * The `CommandQueue.Coordinator` decides which ledgers this node should
      *attempt*, and holds a **reservation** for each attempt from before its
      acquisition task starts until its processor exits. A reservation is
      advisory: it never grants ownership and losing one never revokes a
      grant. `Coordinator.DatabasePolling` is the only strategy in this
      release, selected by `Config.coordinator/0`.
    * `CommandQueue.Lease` decides who actually owns a ledger, through
      PostgreSQL. A `Lease.Grant` is the only thing that fences a write.

  Because a reservation is advisory, two nodes racing for the same ledger is
  not a bug: the loser gets `:held` or `:busy` from `Lease.acquire/4`.

  ## The cap

  A node runs at most `Config.max_leases_per_node/0` processors and at most
  `Config.max_concurrent_acquisitions/0` acquisitions at once. The monitor
  clamps each poll's candidate list to the free slots it computes from the two
  supervisors' live child counts, and `InstanceSupervisor`'s `max_children` is
  the durable backstop: unlike the monitor's arithmetic it survives a monitor
  restart, so a refused `start_child/2` is expected rather than exceptional.

  ## Acquisition tasks

  Every acquisition runs in its own `CommandQueue.AcquireSupervisor` task, so
  one contended ledger cannot block this process. The task acquires, reports
  the grant to the monitor, and waits — with no timer — for the monitor to say
  whether the processor started:

  ```text
  monitor                                task
     |  Task.Supervisor.start_child ----->|
     |                                    |  Lease.acquire/4
     |<--- {:acquired, res, grant, ...} --|  Process.monitor(monitor)
     |  DynamicSupervisor.start_child     |  (still a live child: the lease
     |                                    |   it holds is counted in flight)
     |---- {:start_result, :ok} --------->|  exits, processor owns the lease
     |---- {:start_result, :failed} ----->|  Lease.release(grant, :start_failed)
     |  (monitor dies)                    |  Lease.release(grant, :monitor_down)
  ```

  The task never starts a processor, and the monitor never acquires a lease.
  Whoever holds the grant at the moment of failure is the one that releases
  it, which is what keeps each release single: on a failed start the monitor
  releases the *reservation* and the task releases the *lease*.

  One gap is deliberate (R23.2): if the task dies between its `{:acquired,
  ...}` and the monitor's reply, the reply is lost and nothing releases the
  lease, which then expires by TTL.

  ## Telemetry ordering

  `Lease.emit_acquisition_events/3` is called by the monitor, not by the task
  that acquired, and only after the processor exists and the task has been
  acknowledged. A slow `[:lease, :acquired]` handler therefore delays neither
  the processor nor the task, but it does mean the event is emitted from a
  different process than the one that ran the acquisition transaction.

  ## Other responsibilities

    * Answer `wake/1` so a freshly enqueued command does not wait for the next poll.
    * Use application configuration for poll interval (`:poll_interval` in `:command_queue` config).

  ## Waking on enqueue

  On an otherwise idle queue the poll interval is pure latency: nothing runs
  until the next `:poll`. `DoubleEntryLedger.Stores.CommandStore` therefore
  calls `wake/1` after a successful enqueue when no processor is registered for
  that instance, and this module offers that one instance to the coordinator
  as a candidate, exactly as a poll offers the ones it discovered.

  The wake is an optimization only. It runs no discovery query, it is
  best-effort (see `wake/1`), and the poll remains the guarantee that
  processable work is eventually picked up.

  ## Stranded `:processing` rows

  Rows left `:processing` by a dead owner are rescheduled by the next lease
  acquisition on that ledger (`Lease.acquire/4`). Discovery includes ledgers
  whose only rows are `:processing` under an expired lease, so that happens
  without new work arriving.

  ## Configuration

  The poll interval can be set in your application config:

      config :double_entry_ledger, :command_queue,
        poll_interval: 5_000

  `:poll_interval` is in milliseconds and defaults to 5,000 (5 seconds).

  ## Process Supervision

  This module is intended to be supervised as part of the command queue supervision tree.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.CommandQueue.{Config, InstanceProcessor, Lease}

  @acquire_supervisor DoubleEntryLedger.CommandQueue.AcquireSupervisor
  @instance_supervisor DoubleEntryLedger.CommandQueue.InstanceSupervisor

  # Client API

  @doc """
  Starts the InstanceMonitor GenServer.

  This function is typically called by the supervisor and does not need to be called directly.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Asks the monitor to ensure a processor for `instance_id` now, instead of on
  its next poll, and returns `:ok`.

  Best-effort by design and never blocks the caller:

    * `GenServer.cast/2` to an unregistered name is a silent no-op, so this is
      safe when the command queue is not supervised at all (for example
      `start_command_queue: false`).
    * The woken processor may find nothing to do and shut straight back down —
      see `DoubleEntryLedger.Stores.CommandStore` for why an enqueue is not
      necessarily visible yet — in which case the next poll picks the work up.

  The Registry lookup runs in the calling process and is an ETS read, so a
  burst of enqueues for one instance does not put one message per command into
  this monitor's single mailbox: once a processor is registered, further wakes
  cost a lookup and nothing more. A running processor drains the instance on
  its own.
  """
  @spec wake(Ecto.UUID.t()) :: :ok
  def wake(instance_id) do
    # `Process.whereis/1` first, because `Registry.lookup/2` RAISES when the
    # registry is not started, and building that stacktrace on every enqueue is
    # an order of magnitude dearer than the name lookup (measured: ~9.6us vs
    # ~0.8us per call). A runtime that does not supervise the queue
    # (`start_command_queue: false`, or a node that only enqueues) therefore
    # pays a cheap `nil` instead of an exception per command.
    case Process.whereis(DoubleEntryLedger.CommandQueue.Registry) do
      nil -> :ok
      _registry -> cast_when_idle(instance_id)
    end
  end

  @spec cast_when_idle(Ecto.UUID.t()) :: :ok
  defp cast_when_idle(instance_id) do
    case Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance_id) do
      [] -> GenServer.cast(__MODULE__, {:wake, instance_id})
      [_ | _] -> :ok
    end
  rescue
    # The registry stopped between the lookup above and here.
    ArgumentError -> :ok
  end

  # Server Callbacks

  @impl true
  @doc false
  def init(_) do
    poll_interval = Config.poll_interval()
    coordinator = Config.coordinator()
    schedule_poll(poll_interval)

    {:ok,
     %{
       poll_interval: poll_interval,
       coordinator: coordinator,
       coordinator_state: coordinator.init([]),
       # monitor ref -> %{pid, reservation}, for acquisition tasks and
       # processors alike. The task's pid arrives in the {:acquired, ...}
       # message itself (R22.1). Nothing needs to tell the two apart: a `:DOWN`
       # releases its reservation only when no other ref still holds it, which
       # is what separates a task that handed its reservation to a processor
       # from one that did not, in whichever order the two `:DOWN`s arrive.
       refs: %{}
     }}
  end

  @impl true
  @doc false
  # A wake is one offered candidate; `reserve/2` decides whether this node may
  # attempt it, exactly as on a poll. No discovery query.
  def handle_cast({:wake, instance_id}, state) do
    {:noreply, ensure_processors([instance_id], state)}
  end

  @impl true
  @doc false
  def handle_info(:poll, %{coordinator: coordinator, coordinator_state: cs} = state) do
    {candidates, cs} = coordinator.candidates(cs)
    state = ensure_processors(candidates, %{state | coordinator_state: cs})
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  # The acquisition task acquired the lease and reported the grant; it is now
  # waiting for our reply and is still a live AcquireSupervisor child, so the
  # acquired lease is counted by free_slots/1 until the processor exists
  # (R21.1). Starting the processor is a quick local call, so the monitor does
  # it and hands the reservation to the processor in the same step (R20.2).
  def handle_info({:acquired, reservation, grant, info, task_pid}, state) do
    started =
      DynamicSupervisor.start_child(
        @instance_supervisor,
        {InstanceProcessor, [instance_id: grant.instance_id, grant: grant]}
      )

    handle_start_result(started, reservation, grant, info, task_pid, state)
  end

  # Either an acquisition task ended or a processor exited. A task that
  # succeeded has already handed its reservation to the processor, so its
  # :DOWN must not release; we detect that by checking whether the same
  # reservation is still held under another ref.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    %{coordinator: coordinator, coordinator_state: cs, refs: refs} = state

    case Map.pop(refs, ref) do
      {nil, refs} ->
        # Retired in the start-failure path, or unrelated: nothing to release (R21.3).
        {:noreply, %{state | refs: refs}}

      {%{reservation: reservation}, refs} ->
        still_held? = Enum.any?(refs, fn {_r, %{reservation: res}} -> res == reservation end)
        cs = if still_held?, do: cs, else: coordinator.release(reservation, cs)
        {:noreply, %{state | coordinator_state: cs, refs: refs}}
    end
  end

  # Last clause, so nothing this module expects reaches it. It exists because
  # the monitor's mailbox takes `:DOWN` from two kinds of process and a reply
  # is never sent to it, so an unmatched message would otherwise kill it with a
  # FunctionClauseError. It logs at `:warning` rather than `:debug` on purpose:
  # the message most likely to arrive here is a drifted `{:acquired, ...}`
  # tuple, and a silently dropped protocol message is a silently stranded
  # lease.
  def handle_info(message, state) do
    Logger.warning("InstanceMonitor ignoring unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # Private functions

  # The processor exists: monitor it, acknowledge the task, hand the processor
  # the reservation, and only then emit. Nothing that can fail sits between the
  # monitor and the reply: a slow telemetry handler must never delay it
  # (R22.2), and `processor_started/3` is a pluggable seam — third-party code
  # by design — so a raise there must not cost the task its answer either.
  defp handle_start_result({:ok, pid}, reservation, grant, info, task_pid, state) do
    %{coordinator: coordinator, coordinator_state: cs} = state
    ref = Process.monitor(pid)
    send(task_pid, {:start_result, :ok})
    cs = coordinator.processor_started(reservation, pid, cs)
    Lease.emit_acquisition_events(grant, info)

    entry = %{pid: pid, reservation: reservation}
    {:noreply, %{state | coordinator_state: cs, refs: Map.put(state.refs, ref, entry)}}
  end

  # {:error, :max_children} is the durable lease cap (R14.1); any other reason
  # is a start failure. Retire the task's ref so its :DOWN releases nothing,
  # release the reservation exactly once (R21.3), reply so the task releases
  # its own grant (R21.2), then emit.
  defp handle_start_result({:error, reason}, reservation, grant, info, task_pid, state) do
    %{coordinator: coordinator, coordinator_state: cs} = state
    Logger.warning("could not start processor for #{grant.instance_id}: #{inspect(reason)}")

    # Best effort: if the task died between its send and this reply, the reply
    # is lost and the lease expires by TTL instead (R23.2).
    refs = Map.reject(state.refs, fn {_ref, %{pid: pid}} -> pid == task_pid end)
    cs = coordinator.release(reservation, cs)
    send(task_pid, {:start_result, :failed})
    Lease.emit_acquisition_events(grant, info)

    {:noreply, %{state | coordinator_state: cs, refs: refs}}
  end

  # Strategy-independent: candidates come from the coordinator; this clamps
  # them to free slots, reserves each one before anything else happens
  # (R19.2), starts one acquisition task per reservation, and records the task
  # ref. Each acquisition runs in its own task so one contended ledger never
  # blocks this process.
  defp ensure_processors([], state), do: state

  defp ensure_processors(candidates, state) do
    candidates
    |> Enum.take(free_slots(length(candidates)))
    |> Enum.reduce(state, &attempt/2)
  end

  defp attempt(instance_id, %{coordinator: coordinator, coordinator_state: cs} = state) do
    case coordinator.reserve(instance_id, cs) do
      {:skip, cs} -> %{state | coordinator_state: cs}
      {:ok, reservation, cs} -> start_acquisition(instance_id, reservation, cs, state)
    end
  end

  defp start_acquisition(instance_id, reservation, cs, %{coordinator: coordinator} = state) do
    monitor = self()

    started =
      Task.Supervisor.start_child(@acquire_supervisor, fn ->
        acquire_only(instance_id, reservation, monitor)
      end)

    case started do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        entry = %{pid: pid, reservation: reservation}

        %{
          state
          | coordinator_state: coordinator.acquisition_started(reservation, ref, cs),
            refs: Map.put(state.refs, ref, entry)
        }

      {:error, :max_children} ->
        # Task.Supervisor refused to start a task: no lease was touched, so
        # this is plain contention, like :busy (R15.2). Release the reservation
        # so the next poll may try again.
        Logger.debug("acquisition tasks at max_children; #{instance_id} waits for the next poll")
        %{state | coordinator_state: coordinator.release(reservation, cs)}

      other ->
        # Not reachable through `Task.Supervisor.start_child/2` today. It is
        # matched anyway because the alternative is a CaseClauseError that
        # kills the monitor with the reservation taken and no task started —
        # the one shape from which nothing ever frees the reservation.
        Logger.warning("could not start an acquisition for #{instance_id}: #{inspect(other)}")
        %{state | coordinator_state: coordinator.release(reservation, cs)}
    end
  end

  # Tasks are read from the supervisor, not from the coordinator's reservation
  # map, so acquisitions that survived a monitor restart count. Tasks are read
  # BEFORE processors: a task handing off to a processor between the two reads
  # is counted twice, never zero times, so this can only understate capacity
  # (R15.1).
  defp free_slots(total) do
    in_flight = length(Task.Supervisor.children(@acquire_supervisor))
    active = DynamicSupervisor.count_children(@instance_supervisor).active

    # Both terms are clamped: the double count above can drive the raw
    # difference negative, and Enum.take(list, -1) would then take the LAST
    # candidate instead of none (R17.1).
    lease_slots =
      case Config.max_leases_per_node() do
        :infinity -> total
        cap -> max(cap - active - in_flight, 0)
      end

    acquisition_slots = max(Config.max_concurrent_acquisitions() - in_flight, 0)
    min(lease_slots, acquisition_slots)
  end

  # Runs in an acquisition task. Acquires, reports the grant (with its own pid,
  # R22.1) to the monitor pid it was given, and stays alive until the monitor
  # answers or dies (R22.3), so the acquired lease is counted as in flight
  # until the processor exists (R21.1). On a failed start it releases its own
  # grant (R21.2). On the monitor's :DOWN the unprocessed message died with the
  # mailbox, so releasing is safe. No timer: a slow monitor keeps the task and
  # its slot alive (R22.4), NOT the lease — nothing renews while we wait, so a
  # takeover may happen and the eventual processor then stops on its first
  # `lock!` (R24.1).
  defp acquire_only(instance_id, reservation, monitor) do
    case Lease.acquire(instance_id, Lease.owner_id()) do
      {:ok, grant, info} ->
        monitor_ref = Process.monitor(monitor)
        send(monitor, {:acquired, reservation, grant, info, self()})
        await_start_result(grant, monitor_ref)

      :held ->
        Logger.debug("instance #{instance_id} is owned elsewhere")

      :busy ->
        Logger.debug("instance #{instance_id} lease row busy; retrying on the next poll")
    end

    :ok
  end

  defp await_start_result(grant, monitor_ref) do
    receive do
      {:start_result, :ok} ->
        :ok

      {:start_result, :failed} ->
        Lease.release(grant, :start_failed)

      {:DOWN, ^monitor_ref, :process, _monitor, _reason} ->
        Logger.warning("monitor died before acknowledging #{grant.instance_id}; releasing lease")
        Lease.release(grant, :monitor_down)
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
