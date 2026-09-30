defmodule DoubleEntryLedger.CommandQueue.SupervisorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.CommandQueue.Supervisor module.

  This module ensures that the supervisor and its child processes
  (Registry, DynamicSupervisor, WorkerSupervisor, AcquireSupervisor and
  InstanceMonitor) are started correctly, and that invalid configuration fails
  the supervisor start rather than any single child.
  """

  # Not async: the configuration tests write application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import DoubleEntryLedger.LeaseFixtures, only: [put_queue_config: 1]

  test "starts supervisor and children" do
    {:ok, pid} = start_supervised(DoubleEntryLedger.CommandQueue.Supervisor)
    assert Process.alive?(pid)
    # Registry, DynamicSupervisor, both Task.Supervisors and InstanceMonitor
    # should be started
    assert Process.whereis(DoubleEntryLedger.CommandQueue.Registry)
    assert Process.whereis(DoubleEntryLedger.CommandQueue.InstanceSupervisor)
    assert Process.whereis(DoubleEntryLedger.CommandQueue.WorkerSupervisor)
    assert Process.whereis(DoubleEntryLedger.CommandQueue.AcquireSupervisor)
    assert Process.whereis(DoubleEntryLedger.CommandQueue.InstanceMonitor)
  end

  test "AcquireSupervisor terminates after the monitor that started its tasks" do
    {:ok, _pid} = start_supervised(DoubleEntryLedger.CommandQueue.Supervisor)

    order =
      DoubleEntryLedger.CommandQueue.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    acquire = Enum.find_index(order, &(&1 == DoubleEntryLedger.CommandQueue.AcquireSupervisor))
    monitor = Enum.find_index(order, &(&1 == DoubleEntryLedger.CommandQueue.InstanceMonitor))

    # `which_children/1` reports children in reverse start order, so this list
    # is start order. A task holding an acquired lease releases it on the
    # monitor's :DOWN, so it must still be alive when the monitor dies.
    assert acquire < monitor
  end

  test "invalid configuration fails the supervisor start" do
    put_queue_config(max_concurrent_acquisitions: 0)

    assert {:error, _reason} = start_supervised(DoubleEntryLedger.CommandQueue.Supervisor)
  end

  # A bad VALUE fails the start (above). A key this release stopped reading
  # only warns: it is ignored either way, and refusing to boot over one would
  # have been a further breaking change in the same release.
  test "a key the queue does not read is named at start-up without failing it" do
    put_queue_config(stale_processing_after: 300)

    log =
      capture_log(fn ->
        assert {:ok, pid} = start_supervised(DoubleEntryLedger.CommandQueue.Supervisor)
        assert Process.alive?(pid)
      end)

    assert log =~ "stale_processing_after"
  end

  test "a batch key left at the top level is named at start-up" do
    original = Application.get_env(:double_entry_ledger, :batch_enabled)
    Application.put_env(:double_entry_ledger, :batch_enabled, true)
    on_exit(fn -> restore_batch_enabled(original) end)

    log =
      capture_log(fn ->
        assert {:ok, _pid} = start_supervised(DoubleEntryLedger.CommandQueue.Supervisor)
      end)

    assert log =~ "batch_enabled"
  end

  defp restore_batch_enabled(nil),
    do: Application.delete_env(:double_entry_ledger, :batch_enabled)

  defp restore_batch_enabled(value),
    do: Application.put_env(:double_entry_ledger, :batch_enabled, value)
end
