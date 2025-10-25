defmodule DoubleEntryLedger.CommandQueue.SupervisorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.CommandQueue.Supervisor module.

  This module ensures that the supervisor and its child processes
  (Registry, DynamicSupervisor, and InstanceMonitor) are started correctly.
  """

  use ExUnit.Case, async: true

  test "starts supervisor and children" do
    {:ok, pid} = start_supervised(DoubleEntryLedger.CommandQueue.Supervisor)
    assert Process.alive?(pid)
    # Registry, DynamicSupervisor, and InstanceMonitor should be started
    assert Process.whereis(DoubleEntryLedger.CommandQueue.Registry)
    assert Process.whereis(DoubleEntryLedger.CommandQueue.InstanceSupervisor)
    assert Process.whereis(DoubleEntryLedger.CommandQueue.InstanceMonitor)
  end
end
