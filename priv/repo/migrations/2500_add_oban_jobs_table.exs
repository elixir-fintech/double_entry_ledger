defmodule DoubleEntryLedger.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, Oban)[:prefix]

  def up do
    Oban.Migration.up(version: 12, prefix: @schema_prefix, create_schema: false)
  end

  # We specify `version: 1` in `down`, ensuring that we'll roll all the way back down if
  # necessary, regardless of which version we've migrated `up` to.
  def down do
    Oban.Migration.down(version: 1, prefix: @schema_prefix)
  end
end
