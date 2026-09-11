defmodule DoubleEntryLedger.CommandQueue.InstanceMonitorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.CommandQueue.InstanceMonitor module.

  These tests verify that the InstanceMonitor GenServer starts correctly,
  respects the poll interval configuration, and correctly starts processors
  for instances with pending commands.
  """
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures

  alias DoubleEntryLedger.CommandQueue.{InstanceMonitor, Scheduling}
  alias DoubleEntryLedger.Stores.CommandStore

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

  setup do
    # Ensure the monitor is not already running
    pid = Process.whereis(DoubleEntryLedger.CommandQueue.InstanceMonitor)
    if pid, do: Process.exit(pid, :kill)

    # Also stop any leftover Registry and DynamicSupervisor from previous runs
    for name <- [
          DoubleEntryLedger.CommandQueue.Registry,
          DoubleEntryLedger.CommandQueue.InstanceSupervisor
        ] do
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
    assert pid == Process.whereis(DoubleEntryLedger.CommandQueue.InstanceMonitor)
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

  describe "monitoring behavior" do
    setup [:create_instance, :create_accounts]

    setup do
      start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

      start_supervised!(
        {DynamicSupervisor,
         name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one}
      )

      :ok
    end

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

      Application.put_env(:double_entry_ledger, :command_queue, poll_interval: 100)
      start_supervised!(InstanceMonitor)

      # Wait briefly after first poll for processor to be started (but it may complete quickly)
      Process.sleep(150)

      # The processor was started for this instance. It may have already finished processing
      # and shut down. We verify that either it is still running, or the command was processed
      # (which proves the processor was started).
      registry_result =
        Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance.id)

      command_was_processed =
        case CommandStore.list_for_instance(instance.id) do
          {:ok, {[cmd | _], _meta}} -> cmd.command_queue_item.status != :pending
          _ -> false
        end

      assert registry_result != [] or command_was_processed

      Application.delete_env(:double_entry_ledger, :command_queue)
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

      Application.put_env(:double_entry_ledger, :command_queue, poll_interval: 100)
      start_supervised!(InstanceMonitor)

      # Wait for two poll cycles
      Process.sleep(350)

      result = Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance.id)
      assert length(result) <= 1

      Application.delete_env(:double_entry_ledger, :command_queue)
    end

    test "does not start processor when no commands exist", %{instance: instance} do
      Application.put_env(:double_entry_ledger, :command_queue, poll_interval: 100)
      start_supervised!(InstanceMonitor)

      # Wait for at least one poll cycle
      Process.sleep(250)

      result = Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance.id)
      assert result == []

      Application.delete_env(:double_entry_ledger, :command_queue)
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

      Application.put_env(:double_entry_ledger, :command_queue,
        poll_interval: 60_000,
        stale_processing_after: 1
      )

      start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

      start_supervised!(
        {DynamicSupervisor,
         name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one}
      )

      {:ok, pid} = start_supervised(InstanceMonitor)
      send(pid, :poll)
      # Synchronous call: returns only once the :poll message has been handled.
      :sys.get_state(pid)

      assert CommandStore.get_by_id(command.id).command_queue_item.status == :failed
    end
  end

  describe "stale_processing_after configuration" do
    test "refuses to start when the threshold is zero" do
      put_stale_processing_after(0)

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(InstanceMonitor)

      assert message =~ ":stale_processing_after"
    end

    test "refuses to start when the threshold is negative" do
      put_stale_processing_after(-1)

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(InstanceMonitor)

      assert message =~ ":stale_processing_after"
    end

    test "refuses to start when the threshold is not an integer" do
      put_stale_processing_after("300")

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(InstanceMonitor)

      assert message =~ ":stale_processing_after"
    end

    test "starts when the threshold is a positive integer" do
      put_stale_processing_after(300)

      assert pid = start_supervised!(InstanceMonitor)
      assert Process.alive?(pid)
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
    setup [:create_instance, :create_accounts]

    setup do
      original = Application.get_env(:double_entry_ledger, :command_queue, [])
      on_exit(fn -> Application.put_env(:double_entry_ledger, :command_queue, original) end)

      # A poll interval far longer than the test can run: anything observed
      # here was caused by the enqueue wake, never by the poll.
      Application.put_env(:double_entry_ledger, :command_queue, poll_interval: 60_000)

      start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

      start_supervised!(
        {DynamicSupervisor,
         name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one}
      )

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

      {:ok, _owner} =
        Registry.register(DoubleEntryLedger.CommandQueue.Registry, instance.id, :test_processor)

      test_pid = self()

      {:ok, _command} = CommandStore.create(pending_transaction_attrs(instance, a1, a2))

      # A cast sent by this process before this call is handled before it, so
      # the monitor is guaranteed to be idle by the time this returns.
      :sys.get_state(monitor)

      assert Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance.id) ==
               [{test_pid, :test_processor}]

      assert %{active: 0} =
               DynamicSupervisor.count_children(DoubleEntryLedger.CommandQueue.InstanceSupervisor)
    end

    test "enqueueing does not signal the monitor when a processor is registered", %{
      instance: instance,
      accounts: [a1, a2 | _]
    } do
      # Stand in for the monitor so the signal itself is observable: the
      # Registry check exists so a burst of enqueues for one instance does not
      # put one message per command into the monitor's single mailbox.
      Process.register(self(), InstanceMonitor)

      {:ok, _owner} =
        Registry.register(DoubleEntryLedger.CommandQueue.Registry, instance.id, :test_processor)

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

      # The wake is not work-aware: it starts a processor for the instance, and
      # that processor is what discovers there is nothing to do and stops.
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
      refute Process.whereis(DoubleEntryLedger.CommandQueue.Registry)
      refute Process.whereis(DoubleEntryLedger.CommandQueue.InstanceMonitor)

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

  defp seed_processing_command(instance, processor_id, status \\ :pending, retry_count \\ 0) do
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

    {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, processor_id)
    claimed
  end
end
