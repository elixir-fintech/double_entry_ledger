defmodule DoubleEntryLedger.MigrationTest do
  use DoubleEntryLedger.RepoCase, async: false

  alias DoubleEntryLedger.{Migration, Repo}

  @prefix Application.compile_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")

  describe "latest_version/0" do
    test "returns 5" do
      assert Migration.latest_version() == 5
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
