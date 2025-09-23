defmodule DoubleEntryLedger.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:accounts, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :address, :string, null: false
      add :name, :string
      add :description, :string
      add :currency, :string, null: false
      add :normal_balance, :string, null: false
      add :type, :string, null: false
      add :context, :map, default: %{}
      add :posted, :map, default: %{}
      add :pending, :map, default: %{}
      add :available, :integer, null: false, default: 0
      add :allowed_negative, :boolean, default: true
      add :instance_id, references(:instances, on_delete: :restrict, type: :binary_id), null: false
      add :lock_version, :integer, default: 1 # Optimistic locking

      timestamps(type: :utc_datetime_usec)
    end

    create index(:accounts, [:instance_id], prefix: @schema_prefix)
    create unique_index(:accounts, [:instance_id, :address],
      prefix: @schema_prefix,
      name: "unique_address_per_instance"
    )

  end
end
