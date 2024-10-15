defmodule DoubleEntryLedger.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Enum fields stored as strings
      add :status, :string, null: false, default: "pending"
      add :action, :string, null: false

      add :source, :string, null: false
      add :source_id, :string, null: false
      add :source_data, :map, null: false, default: %{}
      add :processed_at, :utc_datetime_usec

      add :processed_transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id), null: true
      # Embedded schema stored as a JSONB column
      add :transaction_data, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:events, [:inserted_at])
    create index(:events, [:processed_at])
    create index(:events, [:source])
    create index(:events, [:source_id])
  end
end
