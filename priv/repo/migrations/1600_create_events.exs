defmodule DoubleEntryLedger.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true

      add :action, :string, null: false
      add :source, :string, null: false
      add :source_idempk, :string, null: false
      add :source_data, :map, null: false, default: %{}
      add :update_idempk, :string

      add :instance_id, references(:instances, on_delete: :nothing, type: :binary_id), null: false

      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:events, [:inserted_at], prefix: "double_entry_ledger")
    create index(:events, [:source], prefix: "double_entry_ledger")
    create index(:events, [:source_idempk], prefix: "double_entry_ledger")
    create index(:events, [:instance_id], prefix: "double_entry_ledger")
    create index(:events, [:instance_id, :action], prefix: "double_entry_ledger")
    create unique_index(:events, [:instance_id, :source, :source_idempk],
      prefix: "double_entry_ledger",
      name: "unique_for_create_transaction",
      where: "action = 'create_transaction'"
    )
    create unique_index(:events, [:instance_id, :source, :source_idempk, :update_idempk],
      prefix: "double_entry_ledger",
      name: "unique_for_update_transaction",
      where: "action = 'update_transaction'"
    )
  end
end
