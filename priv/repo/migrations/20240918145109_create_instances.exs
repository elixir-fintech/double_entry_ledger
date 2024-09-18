defmodule DoubleEntryLedger.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  def change do
    create table(:instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :description, :string
      add :config, :map, default: %{}
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

  end
end
