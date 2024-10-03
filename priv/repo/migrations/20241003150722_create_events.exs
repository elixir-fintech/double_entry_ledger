defmodule DoubleEntryLedger.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Enum fields stored as strings
      add :status, :string, null: false, default: "pending"
      add :event_type, :string, null: false

      add :source, :string, null: false
      add :source_data, :map, null: false, default: %{}
      add :source_id, :string
      add :processed_at, :utc_datetime_usec

      # Embedded schema stored as a JSONB column
      add :payload, :map

      timestamps(type: :utc_datetime_usec)
    end

    # Optionally, add indexes for performance optimization
    create index(:events, [:inserted_at])
    create index(:events, [:processed_at])
    create index(:events, [:source])
    create index(:events, [:source_id])
  end
end
