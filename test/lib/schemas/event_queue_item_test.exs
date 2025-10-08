defmodule DoubleEntryLedger.EventQueueItemTest do
  @moduledoc """
  Tests for the event queue item schema
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias Ecto.Changeset
  alias DoubleEntryLedger.EventQueueItem

  doctest EventQueueItem

  describe "changeset/2" do
    test "adds default values" do
      assert %EventQueueItem{
               status: :pending,
               processor_version: 1,
               retry_count: 0,
               occ_retry_count: 0,
               errors: []
             } = Changeset.apply_changes(EventQueueItem.changeset(%EventQueueItem{}, %{}))
    end

    test "invalid changeset with invalid status" do
      attrs = %{event_id: Ecto.UUID.generate(), status: "invalid_status"}

      assert %Changeset{errors: [status: {"is invalid", _}]} =
               EventQueueItem.changeset(%EventQueueItem{}, attrs)
    end
  end

  describe "processing_start_changeset/2" do
    test "creates a changeset for processing start" do
      event_queue_item = %EventQueueItem{id: Ecto.UUID.generate()}
      processor_id = "processor_1"

      changeset = EventQueueItem.processing_start_changeset(event_queue_item, processor_id, 1)
      assert changeset.valid?
      assert changeset.changes.status == :processing
      assert changeset.changes.processor_id == processor_id
      assert changeset.changes.retry_count == 1
      assert changeset.changes.processing_started_at
      assert changeset.errors == []
    end
  end
end
