defmodule DoubleEntryLedger.MigrationTest do
  use DoubleEntryLedger.RepoCase, async: false

  alias DoubleEntryLedger.{Migration, Repo}

  @prefix Application.compile_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")

  describe "latest_version/0" do
    test "returns 8" do
      assert Migration.latest_version() == 8
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
      assert trigger_exists?("command_queue_items_set_updated_at")
    end
  end

  defp column_data_type(table, column) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [@prefix, table, column]
      )

    [[type]] = result.rows
    type
  end

  defp column_default(table, column) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT column_default
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [@prefix, table, column]
      )

    [[default]] = result.rows
    default || ""
  end

  defp trigger_exists?(trigger) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT 1
        FROM information_schema.triggers
        WHERE trigger_schema = $1 AND trigger_name = $2
        """,
        [@prefix, trigger]
      )

    result.rows != []
  end

  defp compound_index_exists? do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = $1
          AND tablename = 'balance_history_entries'
          AND indexdef LIKE '%(entry_id, inserted_at)%'
        """,
        [@prefix]
      )

    result.rows != []
  end

  defp single_column_entry_id_index_exists? do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = $1
          AND tablename = 'balance_history_entries'
          AND indexname = 'balance_history_entries_entry_id_index'
        """,
        [@prefix]
      )

    result.rows != []
  end
end
