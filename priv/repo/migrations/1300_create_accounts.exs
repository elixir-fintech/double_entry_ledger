defmodule DoubleEntryLedger.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true
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

    create index(:accounts, [:instance_id], prefix: "double_entry_ledger")
    create unique_index(:accounts, [:instance_id, :name],
      prefix: "double_entry_ledger",
      name: "unique_instance_name"
    )
  end
end
