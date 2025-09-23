defmodule DoubleEntryLedger.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:instances, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :address, :string, null: false
      add :description, :string
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instances, [:address],
      prefix: @schema_prefix,
      name: "unique_address"
    )
  end
end
