defmodule DoubleEntryLedger.Repo.Migrations.AddEventTransactionLinksTable do
  use Ecto.Migration

  def change do
    create table(:event_transaction_links, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, on_delete: :nothing, type: :binary_id), null: false
      add :transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:event_transaction_links, [:event_id], prefix: "double_entry_ledger")
    create index(:event_transaction_links, [:transaction_id], prefix: "double_entry_ledger")
  end
end
