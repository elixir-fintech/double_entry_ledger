defmodule DoubleEntryLedger.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:transactions, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false
      add :posted_at, :utc_datetime_usec
      add :instance_id, references(:instances, on_delete: :restrict, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transactions, [:instance_id], prefix: @schema_prefix)
  end
end
