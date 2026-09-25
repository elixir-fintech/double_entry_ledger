defmodule DoubleEntryLedger.CommandQueue.SupervisorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.CommandQueue.Supervisor module.

  This module ensures that the supervisor and its child processes
  (Registry, DynamicSupervisor, WorkerSupervisor, AcquireSupervisor and
  InstanceMonitor) are started correctly, and that invalid configuration fails
  the supervisor start rather than any single child.
  """

  # Not async: the configuration test writes application environment.
  use ExUnit.Case, async: false

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
end
