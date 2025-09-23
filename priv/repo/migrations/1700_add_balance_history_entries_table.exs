defmodule DoubleEntryLedger.Repo.Migrations.AddBalanceHistoryEntriesTable do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:balance_history_entries, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :posted, :map, default: %{}
      add :pending, :map, default: %{}
      add :available, :integer, null: false, default: 0
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id), null: false
      add :entry_id, references(:entries, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:balance_history_entries, [:account_id], prefix: @schema_prefix)
    create index(:balance_history_entries, [:entry_id], prefix: @schema_prefix)
  end
end
