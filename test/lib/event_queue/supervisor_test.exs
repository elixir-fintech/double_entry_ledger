defmodule DoubleEntryLedger.EventQueue.SupervisorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.EventQueue.Supervisor module.

  This module ensures that the supervisor and its child processes
  (Registry, DynamicSupervisor, and InstanceMonitor) are started correctly.
  """

  use ExUnit.Case, async: true

  test "starts supervisor and children" do
    {:ok, pid} = start_supervised(DoubleEntryLedger.EventQueue.Supervisor)
    assert Process.alive?(pid)
    # Registry, DynamicSupervisor, and InstanceMonitor should be started
    assert Process.whereis(DoubleEntryLedger.EventQueue.Registry)
    assert Process.whereis(DoubleEntryLedger.EventQueue.InstanceSupervisor)
    assert Process.whereis(DoubleEntryLedger.EventQueue.InstanceMonitor)
  end
end
