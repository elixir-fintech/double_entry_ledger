defmodule DoubleEntryLedger.CommandQueue.ConfigTest do
  use ExUnit.Case, async: false

  alias DoubleEntryLedger.CommandQueue.Config

  setup do
    original = Application.get_env(:double_entry_ledger, :command_queue)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:double_entry_ledger, :command_queue)
  defp restore(value), do: Application.put_env(:double_entry_ledger, :command_queue, value)

  test "defaults when nothing is configured" do
    Application.delete_env(:double_entry_ledger, :command_queue)

    assert Config.lease_ttl() == 20
    assert Config.lease_lock_timeout_ms() == 1_000
    assert Config.max_leases_per_node() == :infinity
    assert Config.max_concurrent_acquisitions() == 4
    assert Config.poll_interval() == 5_000
    assert Config.pending_fetch_limit() == 64
    assert Config.batch_enabled?() == false
    assert Config.batch_size() == 8
    assert Config.validate!() == :ok
  end

  test "reads configured values" do
    Application.put_env(:double_entry_ledger, :command_queue,
      lease_ttl: 7,
      lease_lock_timeout_ms: 250,
      max_leases_per_node: 3,
      max_concurrent_acquisitions: 2,
      pending_fetch_limit: 16,
      batch_enabled: true,
      batch_size: 32
    )

    assert Config.lease_ttl() == 7
    assert Config.lease_lock_timeout_ms() == 250
    assert Config.max_leases_per_node() == 3
    assert Config.max_concurrent_acquisitions() == 2
    assert Config.pending_fetch_limit() == 16
    assert Config.batch_enabled?() == true
    assert Config.batch_size() == 32
  end

  test "validate! rejects a non-positive lease_ttl" do
    Application.put_env(:double_entry_ledger, :command_queue, lease_ttl: 0)
    assert_raise ArgumentError, ~r/lease_ttl/, fn -> Config.validate!() end
  end

  test "validate! rejects a non-integer max_concurrent_acquisitions" do
    Application.put_env(:double_entry_ledger, :command_queue, max_concurrent_acquisitions: "4")
    assert_raise ArgumentError, ~r/max_concurrent_acquisitions/, fn -> Config.validate!() end
  end

  test "validate! accepts :infinity for max_leases_per_node" do
    Application.put_env(:double_entry_ledger, :command_queue, max_leases_per_node: :infinity)
    assert Config.validate!() == :ok
  end

  # `:batch_size` and `:batch_enabled` used to be read from the top level with a
  # fallback into `:command_queue`, and a bad value was found by the dispatch
  # path mid-drain. They are queue keys like the rest now, and `validate!/0`
  # rejects them at boot.
  test "validate! rejects a non-positive batch_size" do
    Application.put_env(:double_entry_ledger, :command_queue, batch_size: 0)
    assert_raise ArgumentError, ~r/batch_size/, fn -> Config.validate!() end
  end

  test "validate! rejects a non-integer batch_size" do
    Application.put_env(:double_entry_ledger, :command_queue, batch_size: "8")
    assert_raise ArgumentError, ~r/batch_size/, fn -> Config.validate!() end
  end

  test "validate! rejects a non-boolean batch_enabled" do
    Application.put_env(:double_entry_ledger, :command_queue, batch_enabled: "on")
    assert_raise ArgumentError, ~r/batch_enabled/, fn -> Config.validate!() end
  end

  test "validate! rejects a non-positive pending_fetch_limit" do
    Application.put_env(:double_entry_ledger, :command_queue, pending_fetch_limit: 0)
    assert_raise ArgumentError, ~r/pending_fetch_limit/, fn -> Config.validate!() end
  end

  test "coordination_strategy defaults to :database_polling and maps to the module" do
    Application.delete_env(:double_entry_ledger, :command_queue)

    assert Config.coordination_strategy() == :database_polling
    assert Config.coordinator() == DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling
  end

  test "validate! rejects an unknown coordination_strategy, naming the accepted value" do
    Application.put_env(:double_entry_ledger, :command_queue,
      coordination_strategy: :erlang_cluster
    )

    assert_raise ArgumentError, ~r/coordination_strategy.*database_polling/, fn ->
      Config.validate!()
    end
  end
end
