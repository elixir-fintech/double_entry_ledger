defmodule DoubleEntryLedger.Repo.Migrations.AddBalanceHistoryEntriesTable do
  use Ecto.Migration

  def change do
    create table(:balance_history_entries, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true
      add :posted, :map, default: %{}
      add :pending, :map, default: %{}
      add :available, :integer, null: false, default: 0
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id), null: false
      add :entry_id, references(:entries, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:balance_history_entries, [:account_id], prefix: "double_entry_ledger")
    create index(:balance_history_entries, [:entry_id], prefix: "double_entry_ledger")
  end
end
