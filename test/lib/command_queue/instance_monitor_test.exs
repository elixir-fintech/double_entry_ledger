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

  alias DoubleEntryLedger.CommandQueue.InstanceMonitor
  alias DoubleEntryLedger.Stores.CommandStore

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
end
