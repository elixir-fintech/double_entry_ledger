defmodule DoubleEntryLedger.Repo.Migrations.CreateEventQueueItem do
  use Ecto.Migration

  def change do
    create table(:event_queue_items, primary_key: false, prefix: "double_entry_ledger") do
      add :id, :binary_id, primary_key: true

      add :event_id, references(:events, on_delete: :nothing, type: :binary_id), null: false
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

    create index(:event_queue_items, :processing_completed_at, prefix: "double_entry_ledger")
    create index(:event_queue_items, :status, prefix: "double_entry_ledger")
    create index(:event_queue_items, :next_retry_after, prefix: "double_entry_ledger")
    create index(:event_queue_items, [:next_retry_after, :status], prefix: "double_entry_ledger", name: "idx_event_queue_items_next_retry_status")
    create index(:event_queue_items, [:status, :inserted_at],
      prefix: "double_entry_ledger",
      where: "status = 'dead_letter'",
      name: "idx_event_queue_items_dead_letter_queue")
  end
end
