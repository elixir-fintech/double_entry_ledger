defmodule DoubleEntryLedger.MigrationTest do
  use DoubleEntryLedger.RepoCase, async: false

  alias DoubleEntryLedger.{Migration, Repo}

  @prefix Application.compile_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")

  describe "latest_version/0" do
    test "returns 7" do
      assert Migration.latest_version() == 7
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
