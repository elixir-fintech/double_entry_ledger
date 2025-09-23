defmodule DoubleEntryLedger.Repo.Migrations.CreateEntries do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:entries, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :value, :money_with_currency, null: false
      add :transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id), null: false
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:entries, [:transaction_id], prefix: @schema_prefix)
    create index(:entries, [:account_id], prefix: @schema_prefix)
  end
end
