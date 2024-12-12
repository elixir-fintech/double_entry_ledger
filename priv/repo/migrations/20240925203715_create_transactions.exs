defmodule DoubleEntryLedger.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false
      add :posted_at, :utc_datetime_usec
      add :instance_id, references(:instances, on_delete: :restrict, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transactions, [:instance_id])
  end
end
