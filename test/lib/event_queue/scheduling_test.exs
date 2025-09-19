defmodule DoubleEntryLedger.EventQueue.SchedulingTest do
  @moduledoc """
  Tests for the scheduling of events in the event queue.
  """
  use ExUnit.Case, async: true
  import Mox
  alias Ecto.Changeset
  alias DoubleEntryLedger.EventWorker.UpdateEventError
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
      {:ok, event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))

      event =
        event
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_assoc(:event_queue_item, %{
          id: event.event_queue_item.id,
          status: :processed
        })
        |> Repo.update!()

      assert {:error, :event_not_claimable} =
               Scheduling.claim_event_for_processing(event.id, "manual")
    end

    test "claims an event for processing", %{instance: instance} do
      {:ok, event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))

      assert {:ok, %Event{event_queue_item: eqm} = claimed_event} =
               Scheduling.claim_event_for_processing(event.id, "manual")

      assert eqm.status == :processing
      assert eqm.event_id == claimed_event.id
      assert eqm.processor_id == "manual"
      assert eqm.processing_started_at != nil
      assert eqm.processing_completed_at == nil
      assert eqm.retry_count == 1
      assert eqm.next_retry_after == nil
    end

    test "returns an error when stale entry error occurs", %{instance: instance} do
      {:ok, event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
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
      {:ok, event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))

      %{changes: %{event_queue_item: event_queue_item}} =
        Scheduling.build_mark_as_processed(event)

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == :processed
      assert event_queue_item.changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(event_queue_item, :next_retry_after) == nil
    end
  end

  describe "build_mark_as_dead_letter/2" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to mark event as dead letter", %{instance: instance} do
      {:ok, event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))
      error = "Test error"

      %{changes: %{event_queue_item: event_queue_item}} =
        Scheduling.build_mark_as_dead_letter(event, error)

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == :dead_letter
      assert event_queue_item.changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(event_queue_item, :next_retry_after) == nil
      assert Enum.any?(event_queue_item.changes.errors, fn e -> e.message == error end)
    end
  end

  describe "build_revert_to_pending/2" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to revert event to pending", %{instance: instance} do
      {:ok, pending_event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))
      {:ok, event} = Scheduling.claim_event_for_processing(pending_event.id, "manual")
      error = "Test error"

      %{changes: %{event_queue_item: event_queue_item}} =
        Scheduling.build_revert_to_pending(event, error)

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == :pending
      assert Enum.any?(event_queue_item.changes.errors, fn e -> e.message == error end)
    end
  end

  describe "build_schedule_retry_with_reason" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to schedule retry with reason", %{instance: instance} do
      {:ok, event} = EventStore.create(transaction_event_attrs(instance_address: instance.address))
      error = "Test error"
      reason = :failed

      %{changes: %{event_queue_item: event_queue_item}} =
        Scheduling.build_schedule_retry_with_reason(event, error, reason)

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == reason
      assert event_queue_item.changes.next_retry_after != nil
      assert event_queue_item.changes.retry_count == 1
      assert Enum.any?(event_queue_item.changes.errors, fn e -> e.message == error end)
    end
  end

  describe "build_schedule_update_retry" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to schedule update_retry", %{instance: instance} = ctx do
      %{event: %{source: s, source_idempk: s_id} = pending_event} =
        new_create_transaction_event(ctx, :pending)

      {:error, failed_create_event} =
        DoubleEntryLedger.EventQueue.Scheduling.schedule_retry_with_reason(
          pending_event,
          "some reason",
          :failed
        )

      {:ok, event} = new_update_transaction_event(s, s_id, instance.address, :posted)
      test_message = "Test error"

      error = %UpdateEventError{
        create_event: failed_create_event,
        update_event: event,
        message: test_message,
        reason: :create_event_not_processed
      }

      %{changes: %{event_queue_item: event_queue_item}} =
        Scheduling.build_schedule_update_retry(event, error)

      assert event_queue_item.valid?
      assert event_queue_item.changes.status == :failed
      assert event_queue_item.changes.next_retry_after != nil
      assert Changeset.get_field(event_queue_item, :retry_count) == 0
      assert Enum.any?(event_queue_item.changes.errors, fn e -> e.message == test_message end)
    end
  end
end
