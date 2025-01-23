defmodule DoubleEntryLedger.Repo.Migrations.CreateSchema do
  use Ecto.Migration

  def change do
    execute "CREATE SCHEMA IF NOT EXISTS double_entry_ledger"
  end
end
