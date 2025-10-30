defmodule DoubleEntryLedger.Repo.Migrations.CreateCommandQueueItem do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)

  def change do
    create table(:command_queue_items, primary_key: false, prefix: @schema_prefix) do
      add :id, :binary_id, primary_key: true

      add :command_id, references(:commands, on_delete: :delete_all, type: :binary_id), null: false
      add :status, :string, null: false, default: "pending"

      add :processor_id, :string, null: true
      add :processor_version, :integer, default: 1, null: false
      add :processing_started_at, :utc_datetime_usec
      add :processing_completed_at, :utc_datetime_usec
      add :retry_count, :integer, default: 0, null: false
      add :next_retry_after, :utc_datetime_usec

      add :occ_retry_count, :integer, default: 0, null: false
      add :errors, :jsonb, default: "[]"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:command_queue_items, :command_id, prefix: @schema_prefix)
    create index(:command_queue_items, :processing_completed_at, prefix: @schema_prefix)
    create index(:command_queue_items, :status, prefix: @schema_prefix)
    create index(:command_queue_items, :next_retry_after, prefix: @schema_prefix)
    create index(:command_queue_items, [:next_retry_after, :status], prefix: @schema_prefix, name: "idx_command_queue_items_next_retry_status")
    create index(:command_queue_items, [:status, :inserted_at],
      prefix: @schema_prefix,
      where: "status = 'dead_letter'",
      name: "idx_command_queue_items_dead_letter_queue")
  end
end
