defmodule DoubleEntryLedger.Repo.Migrations.AddEventAccountLinksTable do
  use Ecto.Migration

  def change do
    create table(:event_account_links, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, on_delete: :nothing, type: :binary_id), null: false
      add :account_id, references(:accounts, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:event_account_links, [:event_id], prefix: "double_entry_ledger")
    create index(:event_account_links, [:account_id], prefix: "double_entry_ledger")
  end
end
