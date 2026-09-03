defmodule DoubleEntryLedger.MigrationTest do
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{Migration, Repo}
  alias DoubleEntryLedger.Stores.CommandStore

  @discarded_timestamp ~U[2000-01-01 00:00:00.000000Z]
  @prefix Application.compile_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")

  describe "latest_version/0" do
    test "returns 9" do
      assert Migration.latest_version() == 9
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
