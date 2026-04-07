defmodule DoubleEntryLedger.Repo.Migrations.FixFkConstraintsAndAccountDefaults do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    # Change accounts.instance_id from on_delete: :restrict to on_delete: :nothing
    # so that Ecto's no_assoc_constraint can catch the FK violation (error code 23503
    # instead of 23001). Both prevent deletion, but :nothing is Ecto-compatible.
    drop constraint(:accounts, "accounts_instance_id_fkey", prefix: @schema_prefix)

    alter table(:accounts, prefix: @schema_prefix) do
      modify :instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
    end

    # Same fix for transactions.instance_id
    drop constraint(:transactions, "transactions_instance_id_fkey", prefix: @schema_prefix)

    alter table(:transactions, prefix: @schema_prefix) do
      modify :instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
    end

    # Fix allowed_negative default: schema uses false, migration had true
    alter table(:accounts, prefix: @schema_prefix) do
      modify :allowed_negative, :boolean, default: false
    end
  end
end
