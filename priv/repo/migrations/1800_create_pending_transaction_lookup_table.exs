defmodule DoubleEntryLedger.Repo.Migrations.CreatePendingTransactionLookupTable do
  @moduledoc false
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:pending_transaction_lookup, primary_key: false, prefix: @schema_prefix ) do
      add :instance_id, :text, primary_key: true
      add :source, :text, primary_key: true
      add :source_idempk, :text, primary_key: true

      add :command_id, references(:commands, type: :binary_id, on_delete: :nilify_all)
      add :transaction_id, references(:transactions, type: :binary_id)
      add :journal_event_id, references(:journal_events, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pending_transaction_lookup, [:transaction_id], prefix: @schema_prefix)
    create index(:pending_transaction_lookup, [:journal_event_id], prefix: @schema_prefix)
  end
end
