defmodule DoubleEntryLedger.Repo.Migrations.UniqueIndicesForAccountEvents do
  use Ecto.Migration

  def change do
    create unique_index(:events, [:instance_id, :source, :source_idempk],
      prefix: "double_entry_ledger",
      name: "unique_for_create_account",
      where: "action = 'create_account'"
    )
    create unique_index(:events, [:instance_id, :source, :source_idempk, :update_idempk],
      prefix: "double_entry_ledger",
      name: "unique_for_update_account",
      where: "action = 'update_account'"
    )
  end
end
