defmodule DoubleEntryLedger.Repo.Migrations.CreateIdempotencyKeysTable do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:idempotency_keys, primary_key: false, prefix: @schema_prefix) do
      add :instance_id, references(:instances, on_delete: :nothing, type: :binary_id), null: false
      add :key_hash, :binary, null: false
      add :first_seen_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:idempotency_keys, [:instance_id, :key_hash], prefix: @schema_prefix)

    # this index should help to batch delete idempotency keys to limit load on the database.
    # in order to manage larger volumes, setting up table partitioning would be preferable
    create index(:idempotency_keys, [:instance_id, :first_seen_at], prefix: @schema_prefix)
  end
end
