defmodule DoubleEntryLedger.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true

      # Enum fields stored as strings
      add :status, :string, null: false, default: "pending"
      add :action, :string, null: false

      add :source, :string, null: false
      add :source_idempk, :string, null: false
      add :source_data, :map, null: false, default: %{}
      add :update_idempk, :string
      add :tries, :integer, default: 0
      add :processed_at, :utc_datetime_usec

      add :instance_id, references(:instances, on_delete: :nothing, type: :binary_id), null: false

      add :processed_transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id), null: true
      add :transaction_data, :map, null: false

      add :errors, :jsonb, default: "[]"

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:events, [:inserted_at], prefix: "double_entry_ledger")
    create index(:events, [:processed_at], prefix: "double_entry_ledger")
    create index(:events, [:source], prefix: "double_entry_ledger")
    create index(:events, [:source_idempk], prefix: "double_entry_ledger")
    create index(:events, [:instance_id], prefix: "double_entry_ledger")
    create index(:events, [:processed_transaction_id], prefix: "double_entry_ledger")
    create index(:events, [:instance_id, :status], prefix: "double_entry_ledger")
    create index(:events, [:instance_id, :action], prefix: "double_entry_ledger")
    create unique_index(:events, [:instance_id, :source, :source_idempk],
      prefix: "double_entry_ledger",
      name: "unique_instance_source_source_idempk",
      where: "action = 'create'"
    )
    create unique_index(:events, [:instance_id, :source, :source_idempk, :update_idempk],
      prefix: "double_entry_ledger",
      name: "unique_instance_source_source_idempk_update_idempk",
      where: "action = 'update'"
    )
  end
end
