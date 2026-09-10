defmodule DoubleEntryLedger.EventQueueItemTest do
  @moduledoc """
  Tests for the event queue item schema
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias Ecto.Changeset
  alias DoubleEntryLedger.CommandQueueItem

  doctest CommandQueueItem

  describe "changeset/2" do
    test "adds default values" do
      assert %CommandQueueItem{
               status: :pending,
               processor_version: 1,
               retry_count: 0,
               occ_retry_count: 0,
               errors: []
             } = Changeset.apply_changes(CommandQueueItem.changeset(%CommandQueueItem{}, %{}))
    end

    test "invalid changeset with invalid status" do
      attrs = %{
        event_id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate(),
        status: "invalid_status"
      }

      assert %Changeset{errors: [status: {"is invalid", _}]} =
               CommandQueueItem.changeset(%CommandQueueItem{}, attrs)
    end

    test "does not cast database-managed processing timestamps" do
      attrs = %{
        instance_id: Ecto.UUID.generate(),
        processing_started_at: ~U[2000-01-01 00:00:00.000000Z],
        processing_completed_at: ~U[2000-01-02 00:00:00.000000Z]
      }

      changeset = CommandQueueItem.changeset(%CommandQueueItem{}, attrs)

      refute Changeset.changed?(changeset, :processing_started_at)
      refute Changeset.changed?(changeset, :processing_completed_at)
    end

    test "configures database-managed timestamps to be read after writes" do
      assert :inserted_at in CommandQueueItem.__schema__(:read_after_writes)
      refute :inserted_at in CommandQueueItem.__schema__(:autogenerate_fields)
      assert :updated_at in CommandQueueItem.__schema__(:read_after_writes)
      refute :updated_at in CommandQueueItem.__schema__(:autogenerate_fields)
      assert :processing_started_at in CommandQueueItem.__schema__(:read_after_writes)
      assert :processing_completed_at in CommandQueueItem.__schema__(:read_after_writes)
    end

    test "configures queue_position to be read after writes" do
      assert :queue_position in CommandQueueItem.__schema__(:read_after_writes)
      refute :queue_position in CommandQueueItem.__schema__(:autogenerate_fields)
    end

    test "configures the trigger-managed retry columns to be read after writes" do
      assert :next_retry_after in CommandQueueItem.__schema__(:read_after_writes)
      assert :retry_delay_seconds in CommandQueueItem.__schema__(:read_after_writes)
    end

    test "does not cast the transient retry_delay_seconds instruction" do
      changeset =
        CommandQueueItem.changeset(%CommandQueueItem{}, %{
          instance_id: Ecto.UUID.generate(),
          retry_delay_seconds: 30
        })

      refute Changeset.changed?(changeset, :retry_delay_seconds)
    end
  end

  describe "processing_start_changeset/2" do
    test "creates a changeset for processing start" do
      command_queue_item = %CommandQueueItem{id: Ecto.UUID.generate()}
      processor_id = "processor_1"

      changeset = CommandQueueItem.processing_start_changeset(command_queue_item, processor_id, 1)
      assert changeset.valid?
      assert changeset.changes.status == :processing
      assert changeset.changes.processor_id == processor_id
      assert changeset.changes.retry_count == 1
      refute Changeset.changed?(changeset, :processing_started_at)
      assert changeset.errors == []
    end
  end
end
