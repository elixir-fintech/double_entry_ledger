defmodule DoubleEntryLedger.EventQueue.SchedulingTest do
  @moduledoc """
  Tests for the scheduling of events in the event queue.
  """
  use ExUnit.Case, async: true
  import Mox
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  alias DoubleEntryLedger.{EventStore, Event}
  alias DoubleEntryLedger.EventQueue.Scheduling

  describe "claim_event_for_processing/2" do
    setup [:create_instance, :create_accounts]

    test "returns error when event not found" do
      assert {:error, :event_not_found} =
               Scheduling.claim_event_for_processing(Ecto.UUID.generate(), "manual")
    end

    test "returns error when event not claimable", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))
      event |> Ecto.Changeset.change(%{status: :dead_letter}) |> Repo.update!()

      assert {:error, :event_not_claimable} =
               Scheduling.claim_event_for_processing(event.id, "manual")
    end

    test "claims an event for processing", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{event_queue_item: eqm} = claimed_event} =
               Scheduling.claim_event_for_processing(event.id, "manual")

      assert claimed_event.status == :processing
      assert claimed_event.processor_id == "manual"

      assert eqm.status == :processing
      assert eqm.event_id == claimed_event.id
      assert eqm.processor_id == "manual"
      assert eqm.processing_started_at != nil
      assert eqm.processing_completed_at == nil
      assert eqm.retry_count == 1
      assert eqm.next_retry_after == nil
    end

    test "returns an error when stale entry error occurs", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :event_already_claimed} =
               Scheduling.claim_event_for_processing(
                 event.id,
                 "manual",
                 DoubleEntryLedger.MockRepo
               )
    end
  end

  describe "build_mark_as_processed/1" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to mark event as processed", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      %{changes: %{event_queue_item: event_queue_item} = changes } = changeset = Scheduling.build_mark_as_processed(event)
      assert changeset.valid?
      assert changes.status == :processed
      assert changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(changeset, :next_retry_after) == nil

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == :processed
      assert event_queue_item.changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(event_queue_item, :next_retry_after) == nil

    end
  end

  describe "build_mark_as_dead_letter/2" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to mark event as dead letter", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))
      error = "Test error"

      %{changes: %{event_queue_item: event_queue_item} = changes } = changeset = Scheduling.build_mark_as_dead_letter(event, error)

      assert changeset.valid?
      assert changes.status == :dead_letter
      assert changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(changeset, :next_retry_after) == nil
      assert Enum.any?(changes.errors, fn e -> e.message == error end)

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == :dead_letter
      assert event_queue_item.changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(event_queue_item, :next_retry_after) == nil
      assert Enum.any?(event_queue_item.changes.errors, fn e -> e.message == error end)
    end
  end
end
