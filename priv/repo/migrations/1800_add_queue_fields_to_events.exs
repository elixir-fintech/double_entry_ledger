defmodule DoubleEntryLedger.Repo.Migrations.AddQueueFieldsToEvents do
  use Ecto.Migration

  def change do
    alter table(:events, prefix: "double_entry_ledger") do
      # Add fields for worker-based queue management
      add :processor_id, :string, null: true
      add :processor_version, :integer, default: 1, null: false
      add :processing_started_at, :utc_datetime_usec
      add :processing_completed_at, :utc_datetime_usec
      add :retry_count, :integer, default: 0, null: false
      add :next_retry_after, :utc_datetime_usec
    end

    rename table(:events, prefix: "double_entry_ledger"), :tries, to: :occ_retry_count
    # Create indexes for efficient queue operations
    create index(:events, [:status, :next_retry_after],
      prefix: "double_entry_ledger",
      name: "idx_events_queue_polling"
    )

    create index(:events, [:processor_id, :processing_started_at],
      prefix: "double_entry_ledger",
      name: "idx_events_processor_tracking"
    )

    create index(:events, [:status, :inserted_at],
      prefix: "double_entry_ledger",
      where: "status = 'dead_letter'",
      name: "idx_events_dead_letter_queue"
    )

    # Create partial index for stalled events (processing but no completion after timeout)
    create index(:events, [:processing_started_at],
      prefix: "double_entry_ledger",
      where: "status = 'processing' AND processing_completed_at IS NULL",
      name: "idx_events_stalled_processing"
    )
  end
end
