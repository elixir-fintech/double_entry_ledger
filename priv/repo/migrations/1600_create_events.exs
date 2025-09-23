defmodule DoubleEntryLedger.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:events, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true

      add :action, :string, null: false
      add :source, :string, null: false
      add :source_idempk, :string, null: false
      add :update_idempk, :string
      add :update_source, :string

      add :instance_id, references(:instances, on_delete: :nothing, type: :binary_id), null: false

      add :event_map, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:events, [:inserted_at], prefix: @schema_prefix)
    create index(:events, [:source], prefix: @schema_prefix)
    create index(:events, [:source_idempk], prefix: @schema_prefix)
    create index(:events, [:update_source], prefix: @schema_prefix)
    create index(:events, [:instance_id], prefix: @schema_prefix)
    create index(:events, [:instance_id, :action], prefix: @schema_prefix)
    create unique_index(:events, [:instance_id, :source, :source_idempk],
      prefix: @schema_prefix,
      name: "unique_for_create_transaction",
      where: "action = 'create_transaction'"
    )
    create unique_index(:events, [:instance_id, :source, :source_idempk, :update_idempk],
      prefix: @schema_prefix,
      name: "unique_for_update_transaction",
      where: "action = 'update_transaction'"
    )
    create unique_index(:events, [:instance_id, :source, :source_idempk],
      prefix: @schema_prefix,
      name: "unique_for_create_account",
      where: "action = 'create_account'"
    )
    create unique_index(:events, [:instance_id, :source, :source_idempk, :update_idempk],
      prefix: @schema_prefix,
      name: "unique_for_update_account",
      where: "action = 'update_account'"
    )
  end
end
