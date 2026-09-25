defmodule DoubleEntryLedger.CommandQueue.InstanceMonitorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.CommandQueue.InstanceMonitor module.

  These tests verify that the InstanceMonitor GenServer starts correctly,
  respects the poll interval configuration, acquires a ledger lease before
  starting a processor, and honours the node's lease and acquisition caps.
  """
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.LeaseFixtures
  import ExUnit.CaptureLog

  alias DoubleEntryLedger.CommandQueue.{InstanceMonitor, Lease, Scheduling}
  alias DoubleEntryLedger.CommandQueueItem
  alias DoubleEntryLedger.Stores.CommandStore

  @registry DoubleEntryLedger.CommandQueue.Registry
  @acquire_supervisor DoubleEntryLedger.CommandQueue.AcquireSupervisor
  @instance_supervisor DoubleEntryLedger.CommandQueue.InstanceSupervisor
  @worker_supervisor DoubleEntryLedger.CommandQueue.WorkerSupervisor

  @max_retries Application.compile_env(:double_entry_ledger, :command_queue, [])
               |> Keyword.get(:max_retries, 5)

  defmodule OwnershipRaceRepo do
    @moduledoc false
    # Stages the race the sweep cannot stage from the outside: between the
    # sweep's SELECT and its write, another processor claims the row and
    # advances `processor_version`, so the recovery's optimistic lock is
    # already stale. Only `all/1` is stubbed; the write goes to the real repo.
    import Ecto.Query, only: [from: 2]

    def all(query) do
      rows = DoubleEntryLedger.Repo.all(query)
      command_id = Process.get(:racing_command_id)

      DoubleEntryLedger.Repo.update_all(
        from(eqi in DoubleEntryLedger.CommandQueueItem, where: eqi.command_id == ^command_id),
        inc: [processor_version: 1],
        set: [processor_id: "new-owner"]
      )

      rows
    end

    def update(changeset), do: DoubleEntryLedger.Repo.update(changeset)
  end

  defmodule CountingCoordinator do
    @moduledoc false
    # Wraps DatabasePolling and counts release/2 calls per reservation, so a
    # test can assert exactly one release (R21.3).
    @behaviour DoubleEntryLedger.CommandQueue.Coordinator
    alias DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling

    @impl true
    def init(opts), do: %{inner: DatabasePolling.init(opts), releases: %{}}

    @impl true
    def candidates(%{inner: inner} = state) do
      {ids, inner} = DatabasePolling.candidates(inner)
      {ids, %{state | inner: inner}}
    end

    @impl true
    def reserve(id, %{inner: inner} = state) do
      id |> DatabasePolling.reserve(inner) |> wrap_reserve(state)
    end

    defp wrap_reserve({:ok, reservation, inner}, state),
      do: {:ok, reservation, %{state | inner: inner}}

    defp wrap_reserve({:skip, inner}, state), do: {:skip, %{state | inner: inner}}

    @impl true
    def acquisition_started(reservation, ref, %{inner: inner} = state),
      do: %{state | inner: DatabasePolling.acquisition_started(reservation, ref, inner)}

    @impl true
    def processor_started(reservation, pid, %{inner: inner} = state),
      do: %{state | inner: DatabasePolling.processor_started(reservation, pid, inner)}

    @impl true
    def release(reservation, %{inner: inner, releases: releases} = state) do
      %{
        state
        | inner: DatabasePolling.release(reservation, inner),
          releases: Map.update(releases, reservation, 1, &(&1 + 1))
      }
    end
  end

  setup do
    # Ensure the monitor is not already running
    pid = Process.whereis(InstanceMonitor)
    if pid, do: Process.exit(pid, :kill)

    # Also stop any leftover Registry and supervisors from previous runs
    for name <- [@registry, @instance_supervisor, @acquire_supervisor, @worker_supervisor] do
      case Process.whereis(name) do
        nil -> :ok
        p -> Process.exit(p, :kill)
      end
    end

    # Small delay to let processes terminate
    Process.sleep(50)

    :ok
  end

  test "starts the InstanceMonitor GenServer" do
    assert {:ok, pid} = start_supervised(InstanceMonitor)
    assert Process.alive?(pid)
    assert pid == Process.whereis(InstanceMonitor)
  end

  test "poll interval is set from config or defaults" do
    # Override config for this test
    Application.put_env(:double_entry_ledger, :command_queue, poll_interval: 1234)
    {:ok, pid} = start_supervised(InstanceMonitor)
    state = :sys.get_state(pid)
    assert state.poll_interval == 1234

    # Clean up
    Application.delete_env(:double_entry_ledger, :command_queue)
  end

  test "an unexpected message is logged and leaves the monitor running" do
    {:ok, pid} = start_supervised(InstanceMonitor)

    log =
      capture_log(fn ->
        send(pid, {:acquired, :drifted, :tuple})
        # Handled after the message above, so the log line is already out.
        :sys.get_state(pid)
      end)

    assert log =~ "ignoring unexpected message"
    assert :sys.get_state(pid).refs == %{}
    assert Process.alive?(pid)
  end

  test "the coordinator comes from configuration" do
    {:ok, pid} = start_supervised(InstanceMonitor)

    assert :sys.get_state(pid).coordinator ==
             DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling
  end

  describe "monitoring behavior" do
    setup [:create_instance, :create_accounts, :start_queue_supervisors]

    test "starts a processor for instance with pending commands", %{
      instance: instance,
      accounts: [a1, a2 | _]
    } do
      {:ok, _command} =
        CommandStore.create(
          transaction_command_attrs(
            instance_address: instance.address,
            payload: %DoubleEntryLedger.Command.TransactionData{
              status: :pending,
              entries: [
                %{account_address: a1.address, amount: 100, currency: "EUR"},
                %{account_address: a2.address, amount: 100, currency: "EUR"}
              ]
            }
          )
        )

      put_queue_config(poll_interval: 100)
      start_supervised!(InstanceMonitor)

      # Wait briefly after first poll for processor to be started (but it may complete quickly)
      Process.sleep(250)

      # The processor was started for this instance. It may have already finished processing
      # and shut down. We verify that either it is still running, or the command was processed
      # (which proves the processor was started).
      registry_result = Registry.lookup(@registry, instance.id)

      command_was_processed =
        case CommandStore.list_for_instance(instance.id) do
          {:ok, {[cmd | _], _meta}} -> cmd.command_queue_item.status != :pending
          _ -> false
        end

      assert registry_result != [] or command_was_processed
    end

    test "does not start duplicate processors", %{
      instance: instance,
      accounts: [a1, a2 | _]
    } do
      {:ok, _command} =
        CommandStore.create(
          transaction_command_attrs(
            instance_address: instance.address,
            payload: %DoubleEntryLedger.Command.TransactionData{
              status: :pending,
              entries: [
                %{account_address: a1.address, amount: 100, currency: "EUR"},
                %{account_address: a2.address, amount: 100, currency: "EUR"}
              ]
            }
          )
        )

      put_queue_config(poll_interval: 100)
      start_supervised!(InstanceMonitor)

      # Wait for two poll cycles
      Process.sleep(350)

      result = Registry.lookup(@registry, instance.id)
      assert length(result) <= 1
    end

    test "does not start processor when no commands exist", %{instance: instance} do
      put_queue_config(poll_interval: 100)
      start_supervised!(InstanceMonitor)

      # Wait for at least one poll cycle
      Process.sleep(250)

      assert Registry.lookup(@registry, instance.id) == []
      assert lease_row(instance.id) == nil
    end
  end

  describe "acquiring a lease before starting a processor" do
    setup [:create_instance, :create_accounts, :start_queue_supervisors]

    test "acquires a lease before starting a processor", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 100)
      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      start_supervised!(InstanceMonitor)

      assert_receive {:telemetry_event, ^acquired, _, _, %{instance_id: iid}}, 2_000
      assert iid == instance.id
    end

    test "skips a ledger another owner holds", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      _other = test_grant(instance.id)
      put_queue_config(poll_interval: 100)
      start_supervised!(InstanceMonitor)

      Process.sleep(350)

      assert Registry.lookup(@registry, instance.id) == []
      assert lease_row(instance.id).fencing_token == 1
    end

    test "takes over an expired lease and the token advances", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      _other = test_grant(instance.id)
      expire_lease(instance.id)
      put_queue_config(poll_interval: 100)
      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      start_supervised!(InstanceMonitor)

      assert_receive {:telemetry_event, ^acquired, _, _, %{takeover: true, fencing_token: 2}},
                     2_000
    end

    test "the processor exists before the acquired event is emitted", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 100)
      attach_registry_probe_on_acquired(instance.id)
      start_supervised!(InstanceMonitor)

      assert_receive {:at_emit, lookup, status}, 2_000
      # Tolerates a processor that already drained before emission; either way
      # it existed first.
      assert lookup != [] or status != :pending
    end

    test "wake/1 on an owned ledger is a no-op", %{instance: instance} do
      _other = test_grant(instance.id)
      put_queue_config(poll_interval: 60_000)
      start_supervised!(InstanceMonitor)
      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])

      :ok = InstanceMonitor.wake(instance.id)

      refute_receive {:telemetry_event, ^acquired, _, _, _}, 300
    end

    test "an acquisition task that ends without a processor releases its reservation", %{
      instance: instance
    } do
      _other_owner = test_grant(instance.id)
      put_queue_config(poll_interval: 60_000)
      pid = start_supervised!(InstanceMonitor)

      # A wake offers the ledger even though discovery would filter it out, so
      # the reservation really is taken before `acquire/4` answers `:held`.
      :ok = InstanceMonitor.wake(instance.id)
      :sys.suspend(pid)

      assert map_size(:sys.get_state(pid).coordinator_state.reserved) == 1

      :sys.resume(pid)

      wait_until(fn -> :sys.get_state(pid).coordinator_state.reserved == %{} end)
    end
  end

  describe "the node's caps" do
    setup [:create_instance, :create_accounts, :start_queue_supervisors]

    test "max_leases_per_node clamps how many ledgers one poll attempts", %{instance: instance} do
      other = instance_fixture(address: "cap:second")

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: other.address))
      put_queue_config(poll_interval: 60_000, max_leases_per_node: 1)
      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)

      assert_receive {:telemetry_event, ^acquired, _, _, _}, 2_000
      refute_receive {:telemetry_event, ^acquired, _, _, _}, 300
    end

    test "max_concurrent_acquisitions clamps how many ledgers one poll attempts", %{
      instance: instance
    } do
      other = instance_fixture(address: "cap:concurrent")

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: other.address))

      put_queue_config(
        poll_interval: 60_000,
        max_leases_per_node: :infinity,
        max_concurrent_acquisitions: 1
      )

      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)

      assert_receive {:telemetry_event, ^acquired, _, _, _}, 2_000
      refute_receive {:telemetry_event, ^acquired, _, _, _}, 300
    end

    test "an acquisition already in flight consumes a lease slot", %{instance: instance} do
      # Stands in for a task that survived a monitor restart: it is a live
      # AcquireSupervisor child and nothing else knows about it.
      {:ok, _} =
        Task.Supervisor.start_child(@acquire_supervisor, fn -> Process.sleep(:infinity) end)

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000, max_leases_per_node: 1)
      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)
      :sys.get_state(pid)

      refute_receive {:telemetry_event, ^acquired, _, _, _}, 300
      assert lease_row(instance.id) == nil
      assert :sys.get_state(pid).coordinator_state.reserved == %{}
    end

    test "an acquisition already in flight consumes an acquisition slot", %{instance: instance} do
      {:ok, _} =
        Task.Supervisor.start_child(@acquire_supervisor, fn -> Process.sleep(:infinity) end)

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(
        poll_interval: 60_000,
        max_leases_per_node: :infinity,
        max_concurrent_acquisitions: 1
      )

      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)
      :sys.get_state(pid)

      refute_receive {:telemetry_event, ^acquired, _, _, _}, 300
      assert lease_row(instance.id) == nil
      assert :sys.get_state(pid).coordinator_state.reserved == %{}
    end

    @tag :own_instance_supervisor
    test "more processors than the cap yields zero slots, never a negative take", %{
      instance: instance
    } do
      # Cap 1 in config, but two children already running under an uncapped
      # supervisor, as after a runtime cap decrease. The raw difference is -1;
      # Enum.take(list, -1) would take the LAST candidate.
      start_supervised!({DynamicSupervisor, name: @instance_supervisor, strategy: :one_for_one})

      {:ok, _} = start_filler_child()
      {:ok, _} = start_filler_child()
      assert DynamicSupervisor.count_children(@instance_supervisor).active == 2

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000, max_leases_per_node: 1)
      acquired = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)
      :sys.get_state(pid)

      refute_receive {:telemetry_event, ^acquired, _, _, _}, 300
      assert lease_row(instance.id) == nil
      assert Task.Supervisor.children(@acquire_supervisor) == []
    end

    @tag acquire_max_children: 1
    test "an acquisition task the supervisor refuses releases its reservation", %{
      instance: instance
    } do
      # The AcquireSupervisor's own max_children is the backstop under the
      # monitor's slot arithmetic: it survives a monitor restart, so a refused
      # start_child is contention, not a fault, and must free the reservation.
      {:ok, _} =
        Task.Supervisor.start_child(@acquire_supervisor, fn -> Process.sleep(:infinity) end)

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000, max_concurrent_acquisitions: 4)
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)
      :sys.get_state(pid)

      assert :sys.get_state(pid).coordinator_state.reserved == %{}
      assert lease_row(instance.id) == nil
      assert length(Task.Supervisor.children(@acquire_supervisor)) == 1
    end

    test "a blocked acquisition does not block the monitor process" do
      # A lease row committed outside the sandbox, with its row lock held by a
      # second connection, is the only way to make `Lease.acquire/4` really
      # wait. The ledger is offered through `wake/1` so the monitor needs no
      # database access of its own to reach the acquisition.
      put_queue_config(poll_interval: 60_000, lease_lock_timeout_ms: 1_500)
      probe = probe_connection()
      grant = committed_lease(probe, "probe-holder", 1)
      expire_lease_on_probe(probe, grant)
      hold_lock_on_probe(probe, grant)

      pid = start_supervised!(InstanceMonitor)
      :ok = InstanceMonitor.wake(grant.instance_id)

      wait_until(fn -> length(Task.Supervisor.children(@acquire_supervisor)) == 1 end)

      # The monitor answers while its acquisition task is stuck on the lease
      # row: the acquisition runs in a task, not in this process.
      assert :sys.get_state(pid).poll_interval == 60_000
      assert length(Task.Supervisor.children(@acquire_supervisor)) == 1

      # Let the acquisition give up on the row lock of its own accord. A task
      # killed by teardown while a query is in flight takes the shared sandbox
      # connection down with it.
      wait_until(fn -> Task.Supervisor.children(@acquire_supervisor) == [] end)
    end
  end

  describe "the acquisition protocol" do
    setup [:create_instance, :create_accounts, :start_queue_supervisors]

    test "a reservation is held for the processor's whole life and released on its exit", %{
      instance: instance
    } do
      # Enough work that the processor is provably still draining while the
      # reservation is read back.
      seed_commands(instance, 30)
      put_queue_config(poll_interval: 100)
      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      attach_processor_start_pid()
      pid = start_supervised!(InstanceMonitor)

      assert_receive {:processor_started, processor}, 3_000

      # The acquisition task handed the reservation over and exited. Its :DOWN
      # is already in the monitor's mailbox by the time the task supervisor has
      # noticed, so the `get_state` below is handled after it.
      wait_until(fn -> Task.Supervisor.children(@acquire_supervisor) == [] end)
      :sys.get_state(pid)

      assert Process.alive?(processor)
      assert reserved_processor_pid(pid, instance.id) == processor

      # The processor drains and exits; the reservation goes with it.
      assert_receive {:telemetry_event, ^released, _, _, %{reason: :drained}}, 10_000
      wait_until(fn -> :sys.get_state(pid).coordinator_state.reserved == %{} end)
    end

    test "a suspended monitor keeps the acquired task alive with no release", %{
      instance: instance
    } do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000)
      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      pid = start_supervised!(InstanceMonitor)

      poll_then_suspend(pid)
      wait_until(fn -> lease_row(instance.id) != nil end)

      Process.sleep(1_500)

      assert length(Task.Supervisor.children(@acquire_supervisor)) == 1
      refute_received {:telemetry_event, ^released, _, _, _}
      refute lease_row(instance.id).released_at

      :sys.resume(pid)

      wait_until(fn -> Task.Supervisor.children(@acquire_supervisor) == [] end)
    end

    test "a monitor that dies before acknowledging makes the task release with :monitor_down", %{
      instance: instance
    } do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000)
      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      pid = start_supervised!(InstanceMonitor)

      poll_then_suspend(pid)
      wait_until(fn -> lease_row(instance.id) != nil end)

      Process.exit(pid, :kill)

      assert_receive {:telemetry_event, ^released, _, _, %{reason: :monitor_down}}, 3_000
      assert Registry.lookup(@registry, instance.id) == []
      assert lease_row(instance.id).released_at
    end

    test "a monitor suspended past the TTL yields a stale grant whose processor stops on lease loss",
         %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000, lease_ttl: 1)
      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])
      pid = start_supervised!(InstanceMonitor)

      poll_then_suspend(pid)
      wait_until(fn -> lease_row(instance.id) != nil end)

      # Past the TTL another owner takes over while the task still waits.
      expire_lease(instance.id)
      successor = test_grant(instance.id)
      assert lease_row(instance.id).owner_id == successor.owner_id

      :sys.resume(pid)

      assert_receive {:telemetry_event, ^lost, _, _, %{source: source}}, 5_000
      assert source in [:claim, :transaction]
      assert lease_row(instance.id).owner_id == successor.owner_id
      wait_until(fn -> Task.Supervisor.children(@acquire_supervisor) == [] end)
    end

    test "the task is acknowledged before telemetry runs", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000)
      attach_blocking_acquired_handler()
      pid = start_supervised!(InstanceMonitor)

      send(pid, :poll)

      # While the handler (running in the monitor) blocks, the task has already
      # been acknowledged and is allowed to exit.
      assert_receive {:in_handler, _children_at_emit}, 3_000
      wait_until(fn -> Task.Supervisor.children(@acquire_supervisor) == [] end)
      send(pid, :release_handler)
    end

    @tag :own_instance_supervisor
    test "a start failure emits, releases the reservation once, and the task releases the lease",
         %{instance: instance} do
      # Cap of one, already filled, so the monitor's start_child for `instance`
      # is refused.
      start_supervised!(
        {DynamicSupervisor, name: @instance_supervisor, strategy: :one_for_one, max_children: 1}
      )

      {:ok, _filler} = start_filler_child()

      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      put_queue_config(poll_interval: 60_000)
      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      # The acquired handler blocks inside the monitor, so everything asserted
      # before it is released provably happened before the emit.
      attach_blocking_acquired_handler()
      pid = start_supervised!(InstanceMonitor)

      # Swap in the counting coordinator, then run one real poll so the
      # acquisition task goes through the full protocol.
      :sys.replace_state(pid, &use_counting_coordinator/1)
      send(pid, :poll)

      # The monitor reached the emit, which means the lease was acquired and
      # the start was refused.
      assert_receive {:in_handler, _children_at_emit}, 3_000

      # While it is still blocked there, the task has already been told the
      # start failed, released its own lease, and exited (R22.2 on the failure
      # path too: a slow handler must not hold a lease and an acquisition slot).
      assert_receive {:telemetry_event, ^released, _, _, %{reason: :start_failed}}, 3_000
      wait_until(fn -> Task.Supervisor.children(@acquire_supervisor) == [] end)

      send(pid, :release_handler)

      %{coordinator_state: %{inner: %{reserved: reserved}, releases: releases}} =
        :sys.get_state(pid)

      assert reserved == %{}
      assert releases == %{instance.id => 1}
    end

    @tag :own_instance_supervisor
    test "an {:acquired, ...} from a dead task leaves the lease to expire, reservation released once",
         %{instance: instance} do
      # The task died between its send and the monitor's reply, so the reply is
      # lost and nothing releases the lease (R23.2). The cap is full, so the
      # start fails and the failure path runs.
      start_supervised!(
        {DynamicSupervisor, name: @instance_supervisor, strategy: :one_for_one, max_children: 1}
      )

      {:ok, _filler} = start_filler_child()
      put_queue_config(poll_interval: 60_000)
      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      pid = start_supervised!(InstanceMonitor)

      grant = test_grant(instance.id)
      dead = dead_pid()
      :sys.replace_state(pid, &reserve_under_counting_coordinator(&1, instance.id))

      send(pid, {:acquired, instance.id, grant, fresh_acquire_info(), dead})
      :sys.get_state(pid)

      refute_received {:telemetry_event, ^released, _, _, _}
      refute lease_row(instance.id).released_at

      %{coordinator_state: %{inner: %{reserved: reserved}, releases: releases}} =
        :sys.get_state(pid)

      assert reserved == %{}
      assert releases == %{instance.id => 1}
    end
  end

  describe "stale :processing recovery" do
    setup [:create_instance, :create_accounts]

    setup do
      original = Application.get_env(:double_entry_ledger, :command_queue, [])
      on_exit(fn -> Application.put_env(:double_entry_ledger, :command_queue, original) end)
      :ok
    end

    test "recovers a :processing row older than the threshold", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node")
      age_processing_started_at(command.id, 10)
      put_stale_processing_after(1)

      InstanceMonitor.recover_stale_processing_commands()

      item = CommandStore.get_by_id(command.id).command_queue_item
      assert item.status == :failed
      assert item.processor_id == nil
      assert item.next_retry_after != nil
      assert [%{"message" => message} | _] = item.errors
      assert message =~ "dead-node"
    end

    test "keeps the retry count the claim recorded", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node", :occ_timeout, 2)
      age_processing_started_at(command.id, 10)
      put_stale_processing_after(1)

      InstanceMonitor.recover_stale_processing_commands()

      item = CommandStore.get_by_id(command.id).command_queue_item
      assert item.status == :failed
      # The claim bumped 2 -> 3; the recovery write carries that count through.
      assert item.retry_count == 3
    end

    test "leaves a :processing row younger than the threshold untouched", %{instance: instance} do
      command = seed_processing_command(instance, "live-node")
      put_stale_processing_after(300)

      InstanceMonitor.recover_stale_processing_commands()

      item = CommandStore.get_by_id(command.id).command_queue_item
      assert item.status == :processing
      assert item.processor_id == "live-node"
      assert item.errors == []
      assert item.processor_version == command.command_queue_item.processor_version
    end

    test "dead-letters a recovered command that has exhausted its retries", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node", :occ_timeout, @max_retries - 1)
      age_processing_started_at(command.id, 10)
      put_stale_processing_after(1)

      InstanceMonitor.recover_stale_processing_commands()

      item = CommandStore.get_by_id(command.id).command_queue_item
      assert item.status == :dead_letter
      assert [%{"message" => message} | _] = item.errors
      assert message =~ "Max retry count"
    end

    test "skips the recovery write when a new owner claimed the row first", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node")
      age_processing_started_at(command.id, 10)
      put_stale_processing_after(1)
      Process.put(:racing_command_id, command.id)

      InstanceMonitor.recover_stale_processing_commands(OwnershipRaceRepo)

      item = CommandStore.get_by_id(command.id).command_queue_item
      assert item.status == :processing
      assert item.processor_id == "new-owner"
      assert item.errors == []
    end

    test "emits a recovery telemetry event", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node")
      command_id = command.id
      instance_id = instance.id
      age_processing_started_at(command.id, 10)
      put_stale_processing_after(1)

      ref = attach_telemetry([:double_entry_ledger, :command, :recovered])

      InstanceMonitor.recover_stale_processing_commands()

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :recovered], _m,
                      %{
                        command_id: ^command_id,
                        instance_id: ^instance_id,
                        previous_processor_id: "dead-node",
                        stale_for_seconds: stale_for_seconds
                      }}

      assert stale_for_seconds >= 10
    end

    test "reads the threshold from the command_queue config", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node")
      age_processing_started_at(command.id, 3)
      put_stale_processing_after(2)

      InstanceMonitor.recover_stale_processing_commands()

      assert CommandStore.get_by_id(command.id).command_queue_item.status == :failed
    end

    test "the poll cycle sweeps stale rows", %{instance: instance} do
      command = seed_processing_command(instance, "dead-node")
      age_processing_started_at(command.id, 10)

      put_queue_config(poll_interval: 60_000, stale_processing_after: 1)

      start_supervised!({Registry, keys: :unique, name: @registry})

      start_supervised!({DynamicSupervisor, name: @instance_supervisor, strategy: :one_for_one})

      start_supervised!({Task.Supervisor, name: @acquire_supervisor, max_children: 4})

      {:ok, pid} = start_supervised(InstanceMonitor)
      send(pid, :poll)
      # Synchronous call: returns only once the :poll message has been handled.
      :sys.get_state(pid)

      assert CommandStore.get_by_id(command.id).command_queue_item.status == :failed
    end
  end

  describe "stale_processing_after default" do
    setup [:create_instance, :create_accounts]

    test "recovers a row aged past the 300 second default when unset", %{instance: instance} do
      delete_stale_processing_after()
      command = seed_processing_command(instance, "dead-node")
      age_processing_started_at(command.id, 400)

      InstanceMonitor.recover_stale_processing_commands()

      assert CommandStore.get_by_id(command.id).command_queue_item.status == :failed
    end

    test "leaves a row younger than the 300 second default when unset", %{instance: instance} do
      delete_stale_processing_after()
      command = seed_processing_command(instance, "slow-node")
      age_processing_started_at(command.id, 100)

      InstanceMonitor.recover_stale_processing_commands()

      item = CommandStore.get_by_id(command.id).command_queue_item
      assert item.status == :processing
      assert item.processor_id == "slow-node"
    end
  end

  describe "waking the monitor on enqueue" do
    setup [:create_instance, :create_accounts, :start_queue_supervisors]

    setup do
      # A poll interval far longer than the test can run: anything observed
      # here was caused by the enqueue wake, never by the poll.
      put_queue_config(poll_interval: 60_000)
      :ok
    end

    test "enqueueing starts a processor without waiting for a poll", %{
      instance: instance,
      accounts: [a1, a2 | _]
    } do
      monitor = start_supervised!(InstanceMonitor)
      assert :sys.get_state(monitor).poll_interval == 60_000

      ref = attach_telemetry([:double_entry_ledger, :instance_processor, :start])
      instance_id = instance.id

      {:ok, _command} = CommandStore.create(pending_transaction_attrs(instance, a1, a2))

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :instance_processor, :start],
                      _measurements, %{instance_id: ^instance_id}},
                     2_000
    end

    test "enqueueing does not start a second processor for a registered instance", %{
      instance: instance,
      accounts: [a1, a2 | _]
    } do
      monitor = start_supervised!(InstanceMonitor)

      {:ok, _owner} = Registry.register(@registry, instance.id, :test_processor)

      test_pid = self()

      {:ok, _command} = CommandStore.create(pending_transaction_attrs(instance, a1, a2))

      # A cast sent by this process before this call is handled before it, so
      # the monitor is guaranteed to be idle by the time this returns.
      :sys.get_state(monitor)

      assert Registry.lookup(@registry, instance.id) == [{test_pid, :test_processor}]
      assert %{active: 0} = DynamicSupervisor.count_children(@instance_supervisor)
    end

    test "enqueueing does not signal the monitor when a processor is registered", %{
      instance: instance,
      accounts: [a1, a2 | _]
    } do
      # Stand in for the monitor so the signal itself is observable: the
      # Registry check exists so a burst of enqueues for one instance does not
      # put one message per command into the monitor's single mailbox.
      Process.register(self(), InstanceMonitor)

      {:ok, _owner} = Registry.register(@registry, instance.id, :test_processor)

      {:ok, _command} = CommandStore.create(pending_transaction_attrs(instance, a1, a2))

      refute_receive {:"$gen_cast", {:wake, _instance_id}}, 200
    end

    test "waking an instance with no processable commands leaves no processor running", %{
      instance: instance
    } do
      monitor = start_supervised!(InstanceMonitor)
      attach_processor_start_pid()

      InstanceMonitor.wake(instance.id)
      :sys.get_state(monitor)

      # The wake is not work-aware: it acquires the lease and starts a
      # processor, and that processor is what discovers there is nothing to do
      # and stops.
      assert_receive {:processor_started, processor_pid}, 2_000
      down_ref = Process.monitor(processor_pid)
      assert_receive {:DOWN, ^down_ref, :process, ^processor_pid, _reason}, 2_000

      refute Process.alive?(processor_pid)
    end
  end

  describe "enqueueing without a running command queue" do
    setup [:create_instance]

    test "creating a command succeeds when the Registry and monitor are absent", %{
      instance: instance
    } do
      refute Process.whereis(@registry)
      refute Process.whereis(InstanceMonitor)

      assert {:ok, command} =
               CommandStore.create(
                 transaction_command_attrs(
                   instance_address: instance.address,
                   source_idempk: "queue-absent"
                 )
               )

      assert command.command_queue_item.status == :pending
    end
  end

  # Setup and helpers. Everything with a branch or a loop lives here, never in
  # a test body.

  defp start_queue_supervisors(context) do
    start_supervised!({Registry, keys: :unique, name: @registry})

    start_supervised!(
      {Task.Supervisor, name: @acquire_supervisor, max_children: acquire_max_children(context)}
    )

    # A processor that really starts dispatches into the worker supervisor.
    start_supervised!({Task.Supervisor, name: @worker_supervisor})
    maybe_start_instance_supervisor(context[:own_instance_supervisor])
    :ok
  end

  defp acquire_max_children(context), do: context[:acquire_max_children] || 4

  # A test tagged :own_instance_supervisor starts its own capped supervisor.
  defp maybe_start_instance_supervisor(true), do: :ok

  defp maybe_start_instance_supervisor(_) do
    start_supervised!({DynamicSupervisor, name: @instance_supervisor, strategy: :one_for_one})
  end

  # A child that occupies an InstanceSupervisor slot without holding a lease.
  defp start_filler_child do
    DynamicSupervisor.start_child(@instance_supervisor, %{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> :filler end]},
      restart: :temporary
    })
  end

  defp wait_until(fun, attempts \\ 300) do
    :ok = Enum.reduce_while(1..attempts, :ok, fn _, acc -> poll_once(fun, acc) end)

    assert fun.()
  end

  defp poll_once(fun, acc) do
    if fun.() do
      {:halt, acc}
    else
      Process.sleep(20)
      {:cont, acc}
    end
  end

  # Runs one poll and leaves the monitor suspended afterwards. The `:sys`
  # request is enqueued behind `:poll`, and the acquisition task can only send
  # `{:acquired, ...}` after the poll started it, so the monitor is provably
  # suspended before that message can be handled.
  defp poll_then_suspend(pid) do
    send(pid, :poll)
    :sys.suspend(pid)
    :ok
  end

  defp reserved_processor_pid(monitor, instance_id) do
    monitor
    |> :sys.get_state()
    |> get_in([:coordinator_state, :reserved, instance_id, :processor_pid])
  end

  defp use_counting_coordinator(state) do
    %{state | coordinator: CountingCoordinator, coordinator_state: CountingCoordinator.init([])}
  end

  defp reserve_under_counting_coordinator(state, instance_id) do
    {:ok, _reservation, coordinator_state} =
      CountingCoordinator.reserve(instance_id, CountingCoordinator.init([]))

    %{state | coordinator: CountingCoordinator, coordinator_state: coordinator_state}
  end

  defp fresh_acquire_info, do: %{previous_owner_id: nil, takeover: false, orphans: []}

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    wait_until(fn -> not Process.alive?(pid) end)
    pid
  end

  defp seed_commands(instance, count) do
    Enum.each(1..count, fn n ->
      {:ok, _} =
        CommandStore.create(
          transaction_command_attrs(
            instance_address: instance.address,
            source_idempk: "drain-#{n}-#{System.unique_integer([:positive])}"
          )
        )
    end)
  end

  @doc false
  def forward_processor_pid(_event, _measurements, _metadata, %{test_pid: pid}) do
    send(pid, {:processor_started, self()})
  end

  # Telemetry handlers run in the emitting process, so `self()` in the handler
  # is the InstanceProcessor that just started. That pid is what lets the test
  # wait for its exit instead of sleeping.
  defp attach_processor_start_pid do
    handler_id = "test-processor-start-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:double_entry_ledger, :instance_processor, :start],
      &__MODULE__.forward_processor_pid/4,
      %{test_pid: self()}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc false
  # Runs inside the monitor, which is what makes the block observable: if the
  # acknowledgement came after telemetry the task would still be alive here.
  def block_until_released(_event, _measurements, _metadata, %{test_pid: pid, supervisor: sup}) do
    send(pid, {:in_handler, Task.Supervisor.children(sup)})

    receive do
      :release_handler -> :ok
    end
  end

  defp attach_blocking_acquired_handler do
    handler_id = "slow-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:double_entry_ledger, :lease, :acquired],
      &__MODULE__.block_until_released/4,
      %{test_pid: self(), supervisor: @acquire_supervisor}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc false
  def probe_registry_on_acquired(_event, _measurements, _metadata, %{
        test_pid: pid,
        instance_id: instance_id
      }) do
    lookup = Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance_id)
    status = DoubleEntryLedger.Repo.get_by(CommandQueueItem, instance_id: instance_id).status
    send(pid, {:at_emit, lookup, status})
  end

  defp attach_registry_probe_on_acquired(instance_id) do
    handler_id = "ordering-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:double_entry_ledger, :lease, :acquired],
      &__MODULE__.probe_registry_on_acquired/4,
      %{test_pid: self(), instance_id: instance_id}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp pending_transaction_attrs(instance, account_1, account_2) do
    transaction_command_attrs(
      instance_address: instance.address,
      source_idempk: "wake-#{System.unique_integer([:positive])}",
      payload: %DoubleEntryLedger.Command.TransactionData{
        status: :pending,
        entries: [
          %{account_address: account_1.address, amount: 100, currency: "EUR"},
          %{account_address: account_2.address, amount: 100, currency: "EUR"}
        ]
      }
    )
  end

  defp delete_stale_processing_after do
    :command_queue
    |> restore_command_queue_config_on_exit()
    |> Keyword.delete(:stale_processing_after)
    |> then(&Application.put_env(:double_entry_ledger, :command_queue, &1))
  end

  # Returns the current :command_queue config and registers its restoration, so
  # a test that sets a deliberately invalid threshold cannot leak it into
  # whichever test the seed happens to run next.
  defp restore_command_queue_config_on_exit(key) do
    config = Application.get_env(:double_entry_ledger, key, [])
    on_exit(fn -> Application.put_env(:double_entry_ledger, key, config) end)
    config
  end

  defp put_stale_processing_after(seconds) do
    :command_queue
    |> restore_command_queue_config_on_exit()
    |> Keyword.put(:stale_processing_after, seconds)
    |> then(&Application.put_env(:double_entry_ledger, :command_queue, &1))
  end

  # The claim runs under a real lease owned by `processor_id`, so the queue row
  # carries that owner. `Lease.acquire/4` reschedules orphans, so it has to run
  # before the row is staged.
  defp seed_processing_command(instance, processor_id, status \\ :pending, retry_count \\ 0) do
    {:ok, grant, _info} = Lease.acquire(instance.id, processor_id)

    {:ok, command} =
      CommandStore.create(
        transaction_command_attrs(
          instance_address: instance.address,
          source_idempk: "idempk-#{System.unique_integer([:positive])}"
        )
      )

    command.command_queue_item
    |> Ecto.Changeset.change(%{status: status, retry_count: retry_count})
    |> Repo.update!()

    {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
    claimed
  end
end
