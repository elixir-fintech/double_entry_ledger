defmodule DoubleEntryLedger.Repo.Migrations.CreateJournalEvents do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:journal_events, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:instances, on_delete: :nothing, type: :binary_id), null: false

      add :command_map, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_events, [:inserted_at], prefix: @schema_prefix)
    create index(:journal_events, [:instance_id], prefix: @schema_prefix)
    create index(:journal_events, [
        :instance_id,
        "(command_map->>'action')",
        "(command_map->>'source')",
        "(command_map->>'source_idempk')"
      ],
      name: "idx_journal_events_create_transaction_triple_expr",
      prefix: @schema_prefix,
      include: [:id]
    )
    create index(:journal_events, [
        :instance_id,
        "(command_map->>'source')",
        "(command_map->>'source_idempk')",
        "(command_map->>'update_idempk')"
      ],
      where: "command_map->>'action' = 'update_transaction'",
      name: "idx_journal_events_update_transaction_triple_expr",
      prefix: @schema_prefix,
      include: [:id]
    )
  end
end
