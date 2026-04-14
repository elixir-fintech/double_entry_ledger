defmodule DoubleEntryLedger.Repo.Migrations.SetupDoubleEntryLedger do
  use Ecto.Migration

  def up, do: DoubleEntryLedger.Migration.up()
  def down, do: DoubleEntryLedger.Migration.down()
end
