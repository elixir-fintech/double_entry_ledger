defmodule DoubleEntryLedger.Repo.Migrations.SetupOban do
  use Ecto.Migration

  @oban_prefix Application.compile_env(:double_entry_ledger, Oban)[:prefix] || "public"

  def up do
    Oban.Migration.up(version: 14, prefix: @oban_prefix, create_schema: false)
  end

  def down do
    Oban.Migration.down(version: 1, prefix: @oban_prefix)
  end
end
