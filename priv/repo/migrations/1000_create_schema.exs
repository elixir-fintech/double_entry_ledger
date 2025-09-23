defmodule DoubleEntryLedger.Repo.Migrations.CreateSchema do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    execute "CREATE SCHEMA IF NOT EXISTS #{@schema_prefix}"
  end
end
