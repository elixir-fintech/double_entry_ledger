defmodule DoubleEntryLedger.MigrationTest do
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{CommandQueueItem, Migration, Repo}
  alias DoubleEntryLedger.Stores.CommandStore

  @discarded_timestamp ~U[2000-01-01 00:00:00.000000Z]
  @prefix Application.compile_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")
  @rollback_version 99_999_999_999_999

  # Drives the v10 -> v9 -> v10 transition through the real migrator inside
  # the test's sandbox transaction, so the schema is restored on rollback.
  defmodule RollbackV10 do
    use Ecto.Migration

    def up, do: DoubleEntryLedger.Migration.down(from: 10, version: 9)
    def down, do: DoubleEntryLedger.Migration.up(from: 9)
  end

  describe "latest_version/0" do
    test "returns 10" do
      assert Migration.latest_version() == 10
    end
  end

  describe "v10 migration — database-computed retry deadlines" do
    setup [:create_instance, :create_accounts]

    test "adds a nullable integer retry_delay_seconds column" do
      assert column_data_type("command_queue_items", "retry_delay_seconds") == "integer"
      assert column_nullable?("command_queue_items", "retry_delay_seconds")
    end

    test "teaches the queue trigger to convert the delay into next_retry_after" do
      definition = function_definition("set_command_queue_item_timestamps")

      assert definition =~ "NEW.retry_delay_seconds IS NOT NULL"
      assert definition =~ "make_interval(secs => NEW.retry_delay_seconds)"
      assert definition =~ "NEW.retry_delay_seconds = NULL"
    end

    test "computes next_retry_after from the delay and clears the instruction", %{
      instance: instance
    } do
      retried_queue_item =
        instance
        |> create_queue_item()
        |> Ecto.Changeset.change(
          status: :failed,
          retry_delay_seconds: 45,
          next_retry_after: @discarded_timestamp
        )
        |> Repo.update!()

      assert retried_queue_item.retry_delay_seconds == nil

      assert DateTime.diff(
               retried_queue_item.next_retry_after,
               retried_queue_item.processing_completed_at,
               :second
             ) == 45
    end

    test "leaves an explicit next_retry_after alone when no delay is supplied", %{
      instance: instance
    } do
      explicit = ~U[2030-01-01 12:00:00.000000Z]

      retried_queue_item =
        instance
        |> create_queue_item()
        |> Ecto.Changeset.change(status: :failed, next_retry_after: explicit)
        |> Repo.update!()

      assert retried_queue_item.retry_delay_seconds == nil
      assert retried_queue_item.next_retry_after == explicit
    end
  end

  describe "v10 migration — transient retry_delay_seconds invariant" do
    setup [:create_instance, :create_accounts]

    test "enforces that retry_delay_seconds is never stored" do
      assert constraint_definition("command_queue_items_retry_delay_seconds_transient") ==
               "CHECK ((retry_delay_seconds IS NULL))"
    end

    test "rejects inserting a queue item that carries a retry delay", %{instance: instance} do
      queue_item = create_queue_item(instance)

      assert_raise Ecto.ConstraintError, ~r/retry_delay_seconds_transient/, fn ->
        Repo.insert!(%CommandQueueItem{
          instance_id: instance.id,
          command_id: queue_item.command_id,
          retry_delay_seconds: 5
        })
      end
    end
  end

  describe "v10 migration — rollback" do
    test "down restores the v8 trigger and drops the column, up reapplies both" do
      Ecto.Migrator.run(Repo, [{@rollback_version, RollbackV10}], :up,
        all: true,
        log: false,
        migration_lock: false
      )

      refute column_exists?("command_queue_items", "retry_delay_seconds")
      refute function_definition("set_command_queue_item_timestamps") =~ "retry_delay_seconds"

      Ecto.Migrator.run(Repo, [{@rollback_version, RollbackV10}], :down,
        all: true,
        log: false,
        migration_lock: false
      )

      assert column_data_type("command_queue_items", "retry_delay_seconds") == "integer"

      assert function_definition("set_command_queue_item_timestamps") =~
               "make_interval(secs => NEW.retry_delay_seconds)"

      assert constraint_definition("command_queue_items_retry_delay_seconds_transient") ==
               "CHECK ((retry_delay_seconds IS NULL))"
    end
  end

  describe "v9 migration — stable queue positions" do
    test "adds a required database-generated bigint queue position" do
      assert column_data_type("command_queue_items", "queue_position") == "bigint"
      refute column_nullable?("command_queue_items", "queue_position")

      assert column_default("command_queue_items", "queue_position") =~
               "command_queue_items_queue_position_seq"
    end

    test "orders the in-flight index by queue position" do
      definition = index_definition("idx_command_queue_items_in_flight")

      assert definition =~ "(instance_id, queue_position)"
      assert definition =~ "pending"
      assert definition =~ "occ_timeout"
      assert definition =~ "failed"
    end
  end

  describe "v4 migration — compound (entry_id, inserted_at) index" do
    test "up/1 replaces the single-column (entry_id) index with a compound (entry_id, inserted_at) index" do
      # The test DB has already been migrated to latest during `mix test`
      # setup, so v4 is already applied. Assert the end state directly.
      assert compound_index_exists?()
      refute single_column_entry_id_index_exists?()
    end
  end

  describe "v7 migration — bigint widening for balance/limit columns" do
    test "up/1 widens accounts.available, accounts.negative_limit, and balance_history_entries.available to bigint" do
      assert column_data_type("accounts", "available") == "bigint"
      assert column_data_type("accounts", "negative_limit") == "bigint"
      assert column_data_type("balance_history_entries", "available") == "bigint"
    end
  end

  describe "v8 migration — database-generated command queue timestamps" do
    test "commands and command_queue_items use the PostgreSQL clock for inserted_at" do
      assert column_default("commands", "inserted_at") =~ "statement_timestamp()"
      assert column_default("command_queue_items", "inserted_at") =~ "statement_timestamp()"
    end

    test "command_queue_items use the PostgreSQL clock for updated_at" do
      assert column_default("command_queue_items", "updated_at") =~ "statement_timestamp()"
      assert trigger_exists?("command_queue_items_set_timestamps")
    end
  end

  describe "processing timestamp trigger" do
    setup [:create_instance, :create_accounts]

    test "stamps processing_started_at when processing starts", %{instance: instance} do
      queue_item = create_queue_item(instance)

      processing_queue_item =
        queue_item
        |> Ecto.Changeset.change(
          status: :processing,
          processing_started_at: @discarded_timestamp
        )
        |> Repo.update!()

      assert processing_queue_item.processing_started_at == processing_queue_item.updated_at
      assert processing_queue_item.processing_completed_at == nil
    end

    test "stamps processing_completed_at when processing succeeds", %{instance: instance} do
      assert_completion_timestamp(instance, :processed)
    end

    test "stamps processing_completed_at when processing fails", %{instance: instance} do
      assert_completion_timestamp(instance, :failed)
    end

    test "stamps processing_completed_at after an OCC timeout", %{instance: instance} do
      assert_completion_timestamp(instance, :occ_timeout)
    end

    test "stamps processing_completed_at when a command is dead-lettered", %{
      instance: instance
    } do
      assert_completion_timestamp(instance, :dead_letter)
    end
  end

  defp create_queue_item(instance) do
    assert {:ok, command} =
             CommandStore.create(transaction_command_attrs(instance_address: instance.address))

    command.command_queue_item
  end

  defp assert_completion_timestamp(instance, status) do
    completed_queue_item =
      instance
      |> create_queue_item()
      |> Ecto.Changeset.change(status: :processing)
      |> Repo.update!()
      |> Ecto.Changeset.change(
        status: status,
        processing_completed_at: @discarded_timestamp
      )
      |> Repo.update!()

    assert completed_queue_item.processing_completed_at == completed_queue_item.updated_at
  end

  defp column_data_type(table, column) do
    single_value(
      """
      SELECT data_type
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
      """,
      [@prefix, table, column]
    )
  end

  defp column_default(table, column) do
    single_value(
      """
      SELECT column_default
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
      """,
      [@prefix, table, column]
    ) || ""
  end

  defp column_exists?(table, column) do
    exists?(
      """
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
      """,
      [@prefix, table, column]
    )
  end

  defp constraint_definition(constraint) do
    single_value(
      """
      SELECT pg_get_constraintdef(c.oid)
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = $1 AND c.conname = $2
      """,
      [@prefix, constraint]
    )
  end

  defp column_nullable?(table, column) do
    single_value(
      """
      SELECT is_nullable = 'YES'
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
      """,
      [@prefix, table, column]
    )
  end

  defp index_definition(index) do
    single_value(
      """
      SELECT indexdef
      FROM pg_indexes
      WHERE schemaname = $1 AND indexname = $2
      """,
      [@prefix, index]
    )
  end

  defp function_definition(function) do
    single_value(
      """
      SELECT pg_get_functiondef(p.oid)
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = $1 AND p.proname = $2
      """,
      [@prefix, function]
    )
  end

  defp trigger_exists?(trigger) do
    exists?(
      """
      SELECT 1
      FROM information_schema.triggers
      WHERE trigger_schema = $1 AND trigger_name = $2
      """,
      [@prefix, trigger]
    )
  end

  defp compound_index_exists? do
    exists?(
      """
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = $1
        AND tablename = 'balance_history_entries'
        AND indexdef LIKE '%(entry_id, inserted_at)%'
      """,
      [@prefix]
    )
  end

  defp single_column_entry_id_index_exists? do
    exists?(
      """
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = $1
        AND tablename = 'balance_history_entries'
        AND indexname = 'balance_history_entries_entry_id_index'
      """,
      [@prefix]
    )
  end

  defp single_value(sql, args) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, args)
    value
  end

  defp exists?(sql, args) do
    Ecto.Adapters.SQL.query!(Repo, sql, args).num_rows > 0
  end
end
