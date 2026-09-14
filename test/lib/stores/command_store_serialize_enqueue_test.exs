defmodule DoubleEntryLedger.Stores.CommandStoreSerializeEnqueueTest do
  @moduledoc """
  Tests the opt-in `:serialize_enqueue` flag on `CommandStore.create/1`.

  The flag makes every enqueue take a transaction-scoped PostgreSQL advisory
  lock keyed on the instance, so queue positions for one ledger are allocated
  in commit order. The sandbox wraps each test in a transaction, so a lock
  taken by `create/1` stays held for the rest of the test. A second, raw
  Postgrex connection probes it: `pg_try_advisory_lock/2` on the same key
  returns `false` while another session holds the lock.

  The sandbox also shares one session between all processes in a test, and
  advisory locks are reentrant within a session, so two `create/1` calls
  cannot block each other here. The blocking tests instead hold the ledger's
  lock from the probe session and watch the queue-position sequence: it must
  not advance while the enqueue is waiting, which proves the lock is taken
  before the position is allocated.

  Toggles application env, so it cannot run async.
  """
  use ExUnit.Case, async: false
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{Command, Config}
  alias DoubleEntryLedger.Stores.CommandStore

  setup [:create_instance, :create_accounts, :open_probe_connection]

  describe "create/1 with :serialize_enqueue enabled" do
    setup [:enable_serialize_enqueue]

    test "Config.serialize_enqueue?/0 reports the flag" do
      assert Config.serialize_enqueue?()
    end

    test "holds the ledger's enqueue lock until the enqueue transaction ends", ctx do
      assert {:ok, _command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      refute enqueue_lock_available?(ctx.probe, ctx.instance.id)
    end

    test "holds the lock on the pending create_transaction path too", %{
      instance: instance,
      probe: probe
    } do
      assert {:ok, _command} =
               CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      refute enqueue_lock_available?(probe, instance.id)
    end

    test "locks one ledger, not the whole queue", ctx do
      other = instance_fixture(address: "other:address")

      assert {:ok, _command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert enqueue_lock_available?(ctx.probe, other.id)
    end

    test "an enqueue waits for the ledger lock and allocates no queue position while waiting",
         ctx do
      hold_ledger_lock(ctx.probe, ctx.instance.id)
      position_before = queue_position_sequence_value(ctx.probe)
      command_map = create_transaction_command_map(ctx, :posted)

      enqueue = Task.async(fn -> CommandStore.create(command_map) end)

      assert Task.yield(enqueue, 300) == nil
      assert queue_position_sequence_value(ctx.probe) == position_before

      release_ledger_lock(ctx.probe, ctx.instance.id)

      assert {:ok, %Command{command_queue_item: %{queue_position: position}}} =
               Task.await(enqueue, 5_000)

      assert position > position_before
    end

    test "an enqueue for another ledger does not wait on a held ledger lock", ctx do
      other = instance_fixture(address: "other:address")
      hold_ledger_lock(ctx.probe, ctx.instance.id)
      command_map = account_command_attrs(instance_address: other.address)

      enqueue = Task.async(fn -> CommandStore.create(command_map) end)

      assert {:ok, %Command{}} = Task.await(enqueue, 5_000)
    end
  end

  describe "create/1 with :serialize_enqueue at its default" do
    test "Config.serialize_enqueue?/0 defaults to false" do
      refute Config.serialize_enqueue?()
    end

    test "does not take an enqueue lock", ctx do
      assert {:ok, _command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert enqueue_lock_available?(ctx.probe, ctx.instance.id)
    end
  end

  defp enable_serialize_enqueue(_ctx) do
    Application.put_env(:double_entry_ledger, :serialize_enqueue, true)
    on_exit(fn -> Application.delete_env(:double_entry_ledger, :serialize_enqueue) end)
    :ok
  end

  # A connection outside the sandbox pool. It is linked to the test process,
  # so it closes (releasing any session lock it took) when the test ends.
  defp open_probe_connection(_ctx) do
    config = Application.fetch_env!(:double_entry_ledger, DoubleEntryLedger.Repo)
    port = config |> Keyword.fetch!(:port) |> to_string() |> String.to_integer()

    {:ok, probe} =
      Postgrex.start_link(
        hostname: Keyword.fetch!(config, :hostname),
        username: Keyword.fetch!(config, :username),
        password: Keyword.fetch!(config, :password),
        database: Keyword.fetch!(config, :database),
        port: port
      )

    %{probe: probe}
  end

  # Session-level lock on the same key `create/1` takes, held by the probe
  # session until released or the probe disconnects.
  defp hold_ledger_lock(probe, instance_id) do
    Postgrex.query!(
      probe,
      "SELECT pg_advisory_lock($1, hashtext($2::text))",
      [CommandStore.enqueue_lock_namespace(), instance_id]
    )

    :ok
  end

  defp release_ledger_lock(probe, instance_id) do
    %Postgrex.Result{rows: [[true]]} =
      Postgrex.query!(
        probe,
        "SELECT pg_advisory_unlock($1, hashtext($2::text))",
        [CommandStore.enqueue_lock_namespace(), instance_id]
      )

    :ok
  end

  # Sequences are not transactional, so a position allocated inside the
  # blocked sandbox transaction is visible here immediately.
  defp queue_position_sequence_value(probe) do
    %Postgrex.Result{rows: [[value]]} =
      Postgrex.query!(
        probe,
        "SELECT last_value FROM #{Config.schema_prefix()}.command_queue_items_queue_position_seq",
        []
      )

    value
  end

  defp enqueue_lock_available?(probe, instance_id) do
    %Postgrex.Result{rows: [[available]]} =
      Postgrex.query!(
        probe,
        "SELECT pg_try_advisory_lock($1, hashtext($2::text))",
        [CommandStore.enqueue_lock_namespace(), instance_id]
      )

    available
  end
end
