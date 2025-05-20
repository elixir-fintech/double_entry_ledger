defmodule DoubleEntryLedger.EventQueue.InstanceMonitorTest do
  @moduledoc """
  Tests for the DoubleEntryLedger.EventQueue.InstanceMonitor module.

  These tests verify that the InstanceMonitor GenServer starts correctly and
  respects the poll interval configuration.
  """
  use ExUnit.Case, async: false

  alias DoubleEntryLedger.EventQueue.InstanceMonitor

  setup do
    # Ensure the monitor is not already running
    pid = Process.whereis(DoubleEntryLedger.EventQueue.InstanceMonitor)
    if pid, do: Process.exit(pid, :kill)
    :ok
  end

  test "starts the InstanceMonitor GenServer" do
    assert {:ok, pid} = start_supervised(InstanceMonitor)
    assert Process.alive?(pid)
    assert pid == Process.whereis(DoubleEntryLedger.EventQueue.InstanceMonitor)
  end

  test "poll interval is set from config or defaults" do
    # Override config for this test
    Application.put_env(:double_entry_ledger, :event_queue, poll_interval: 1234)
    {:ok, pid} = start_supervised(InstanceMonitor)
    state = :sys.get_state(pid)
    assert state.poll_interval == 1234

    # Clean up
    Application.delete_env(:double_entry_ledger, :event_queue)
  end
end
