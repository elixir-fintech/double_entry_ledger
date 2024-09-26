defmodule DoubleEntryLedger.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false
      add :event_id, :string
      add :posted_at, :utc_datetime_usec
      add :effective_at, :utc_datetime_usec
      add :metadata, :map, default: %{}
      add :instance_id, references(:instances, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transactions, [:instance_id])
  end
end
