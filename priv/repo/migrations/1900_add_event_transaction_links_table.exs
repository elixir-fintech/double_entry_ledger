defmodule DoubleEntryLedger.Repo.Migrations.AddEventTransactionLinksTable do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:event_transaction_links, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, on_delete: :nothing, type: :binary_id), null: false
      add :transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id), null: false
      add :journal_event_id, references(:journal_events, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:event_transaction_links, [:event_id], prefix: @schema_prefix)
    create index(:event_transaction_links, [:transaction_id], prefix: @schema_prefix)
    create index(:event_transaction_links, [:journal_event_id], prefix: @schema_prefix)
    create unique_index(:event_transaction_links, [:transaction_id, :journal_event_id],  prefix: @schema_prefix)
  end
end
