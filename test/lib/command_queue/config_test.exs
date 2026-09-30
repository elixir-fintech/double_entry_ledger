defmodule DoubleEntryLedger.CommandQueue.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DoubleEntryLedger.CommandQueue.Config

  setup do
    original = Application.get_env(:double_entry_ledger, :command_queue)
    # `warn_stale_config/0` also looks at two TOP-LEVEL keys, so they have to
    # be saved and put back as well.
    batch_enabled = Application.get_env(:double_entry_ledger, :batch_enabled)
    batch_size = Application.get_env(:double_entry_ledger, :batch_size)
    pending_fetch_limit = Application.get_env(:double_entry_ledger, :pending_fetch_limit)

    on_exit(fn ->
      restore(original)
      restore_top_level(:batch_enabled, batch_enabled)
      restore_top_level(:batch_size, batch_size)
      restore_top_level(:pending_fetch_limit, pending_fetch_limit)
    end)

    :ok
  end

  defp restore(nil), do: Application.delete_env(:double_entry_ledger, :command_queue)
  defp restore(value), do: Application.put_env(:double_entry_ledger, :command_queue, value)

  defp restore_top_level(key, nil), do: Application.delete_env(:double_entry_ledger, key)
  defp restore_top_level(key, value), do: Application.put_env(:double_entry_ledger, key, value)

  # Every key the list may legitimately carry, spelled out rather than taken
  # from `known_keys/0`, so a wrong entry there cannot make this pass.
  defp full_legitimate_list do
    [
      poll_interval: 5_000,
      lease_ttl: 20,
      lease_lock_timeout_ms: 1_000,
      max_leases_per_node: :infinity,
      max_concurrent_acquisitions: 4,
      coordination_strategy: :database_polling,
      pending_fetch_limit: 64,
      batch_enabled: false,
      batch_size: 8,
      max_retries: 5,
      base_retry_delay: 30,
      max_retry_delay: 3_600,
      processor_name: "command_queue"
    ]
  end

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

  # `validate!/0` raises on a bad VALUE. `warn_stale_config/0` warns about a
  # key this release stopped reading: an unknown one inside the list, or one
  # of the two that moved into the list still set at the top level. Both
  # upgrade hazards are otherwise silent.

  test "warn_stale_config says nothing when nothing is configured" do
    Application.delete_env(:double_entry_ledger, :command_queue)
    Application.delete_env(:double_entry_ledger, :batch_enabled)
    Application.delete_env(:double_entry_ledger, :batch_size)

    assert capture_log(fn -> assert Config.warn_stale_config() == :ok end) == ""
  end

  test "warn_stale_config says nothing about the full legitimate key set" do
    Application.put_env(:double_entry_ledger, :command_queue, full_legitimate_list())
    Application.delete_env(:double_entry_ledger, :batch_enabled)
    Application.delete_env(:double_entry_ledger, :batch_size)

    assert capture_log(fn -> Config.warn_stale_config() end) == ""
  end

  test "warn_stale_config says nothing about processor_name, which Lease reads" do
    Application.put_env(:double_entry_ledger, :command_queue, processor_name: "px")

    assert capture_log(fn -> Config.warn_stale_config() end) == ""
  end

  test "warn_stale_config says nothing about the three compile-time retry keys" do
    Application.put_env(:double_entry_ledger, :command_queue,
      max_retries: 5,
      base_retry_delay: 30,
      max_retry_delay: 3_600
    )

    assert capture_log(fn -> Config.warn_stale_config() end) == ""
  end

  test "warn_stale_config names a removed key left in the list" do
    Application.put_env(:double_entry_ledger, :command_queue, stale_processing_after: 300)

    log = capture_log(fn -> Config.warn_stale_config() end)

    assert log =~ "stale_processing_after"
    assert log =~ "[warning]"
  end

  # The message names the offending keys from the environment, not from a
  # hard-coded list: `unified_fencing_test.exs` forbids lib/ from mentioning a
  # removed mechanism by name, and a dynamic message needs no editing when the
  # next key goes.
  test "warn_stale_config points at the changelog for what was removed" do
    Application.put_env(:double_entry_ledger, :command_queue, stale_processing_after: 300)

    assert capture_log(fn -> Config.warn_stale_config() end) =~ "0.6.0 CHANGELOG"
  end

  test "warn_stale_config lists the known keys so the message is actionable" do
    Application.put_env(:double_entry_ledger, :command_queue, nonsense: 1)

    assert capture_log(fn -> Config.warn_stale_config() end) =~ "lease_ttl"
  end

  test "warn_stale_config names every unknown key in one message" do
    Application.put_env(:double_entry_ledger, :command_queue, first_typo: 1, second_typo: 2)

    log = capture_log(fn -> Config.warn_stale_config() end)

    assert log =~ "first_typo"
    assert log =~ "second_typo"
  end

  test "warn_stale_config returns :ok rather than raising on an unknown key" do
    Application.put_env(:double_entry_ledger, :command_queue, stale_processing_after: 300)

    capture_log(fn -> assert Config.warn_stale_config() == :ok end)
  end

  test "warn_stale_config does not raise when the list is not a keyword list" do
    Application.put_env(:double_entry_ledger, :command_queue, "nonsense")

    assert capture_log(fn -> assert Config.warn_stale_config() == :ok end) == ""
  end

  test "warn_stale_config names batch_enabled left at the top level" do
    Application.delete_env(:double_entry_ledger, :command_queue)
    Application.put_env(:double_entry_ledger, :batch_enabled, true)
    Application.delete_env(:double_entry_ledger, :batch_size)

    log = capture_log(fn -> Config.warn_stale_config() end)

    assert log =~ "batch_enabled"
    assert log =~ ":command_queue"
  end

  test "warn_stale_config names batch_size left at the top level" do
    Application.delete_env(:double_entry_ledger, :command_queue)
    Application.delete_env(:double_entry_ledger, :batch_enabled)
    Application.put_env(:double_entry_ledger, :batch_size, 16)

    assert capture_log(fn -> Config.warn_stale_config() end) =~ "batch_size"
  end

  # The default is not always what applies: a correctly placed value wins, so
  # the message must not claim the defaults are in force.
  test "the relocated-key warning says the :command_queue value applies if set" do
    Application.put_env(:double_entry_ledger, :command_queue, batch_size: 32)
    Application.delete_env(:double_entry_ledger, :batch_enabled)
    Application.put_env(:double_entry_ledger, :batch_size, 16)

    assert capture_log(fn -> Config.warn_stale_config() end) =~
             "the :command_queue value applies if set"
  end

  test "the relocated-key warning names only the offending key's default" do
    Application.delete_env(:double_entry_ledger, :command_queue)
    Application.delete_env(:double_entry_ledger, :batch_enabled)
    Application.put_env(:double_entry_ledger, :batch_size, 16)

    assert capture_log(fn -> Config.warn_stale_config() end) =~ "(batch_size: 8)"
  end

  test "a top-level batch key does not stop the correctly placed one working" do
    Application.put_env(:double_entry_ledger, :command_queue, batch_size: 32)
    Application.put_env(:double_entry_ledger, :batch_size, 16)

    capture_log(fn -> Config.warn_stale_config() end)

    assert Config.batch_size() == 32
  end

  # Only `:batch_enabled` and `:batch_size` moved out of the top level in
  # 0.6.0. `:pending_fetch_limit` was already a queue key in 0.5.0 and was
  # never read from the top level, so a stray top-level one is not something
  # this release broke and is not reported.
  test "pending_fetch_limit at the top level is not reported as relocated" do
    Application.delete_env(:double_entry_ledger, :command_queue)
    Application.delete_env(:double_entry_ledger, :batch_enabled)
    Application.delete_env(:double_entry_ledger, :batch_size)
    Application.put_env(:double_entry_ledger, :pending_fetch_limit, 16)

    assert capture_log(fn -> Config.warn_stale_config() end) == ""
  end
end
