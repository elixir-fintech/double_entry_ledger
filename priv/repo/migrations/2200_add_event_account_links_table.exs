defmodule DoubleEntryLedger.Repo.Migrations.AddEventAccountLinksTable do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:event_account_links, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, on_delete: :nothing, type: :binary_id), null: false
      add :account_id, references(:accounts, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:event_account_links, [:event_id], prefix: @schema_prefix)
    create index(:event_account_links, [:account_id], prefix: @schema_prefix)
  end
end
