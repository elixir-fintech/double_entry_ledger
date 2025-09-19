defmodule DoubleEntryLedger.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  def change do
    create table(:instances, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true
      add :address, :string
      add :description, :string
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instances, [:address],
      prefix: "double_entry_ledger",
      name: "unique_address"
    )
  end
end
