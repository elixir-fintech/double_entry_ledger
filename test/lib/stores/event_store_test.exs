defmodule DoubleEntryLedger.EventStoreTest do
  @moduledoc """
  This module tests the EventStore module.
  """
  use ExUnit.Case, async: true
  import Mox
  alias DoubleEntryLedger.CreateEvent
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.{EventStore, EventStoreHelper, Event}
  alias DoubleEntryLedger.EventWorker.CreateEvent

  describe "create/1" do
    setup [:create_instance]

    test "inserts a new event and adds an event_queue_item", %{instance: instance} do
      assert {:ok, %Event{id: id} = event} = EventStore.create(event_attrs(instance_id: instance.id))
      assert event.status == :pending
      assert event.processed_at == nil
      assert event.occ_retry_count == 0

      assert %{id: evq_id, event_id: ^id, status: :pending} = event.event_queue_item
      assert evq_id != nil
    end
  end

  describe "get_create_event_by_source/3" do
    setup [:create_instance, :create_accounts]

    test "gets an event by source", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert %Event{} =
               found_event =
               EventStoreHelper.get_create_event_by_source(
                 event.source,
                 event.source_idempk,
                 instance.id
               )

      assert found_event.id == event.id
    end

    test "returns processed_transaction", %{instance: instance} = ctx do
      %{event: event} = create_event(ctx, :pending)
      {:ok, transaction, _} = CreateEvent.process_create_event(event)

      assert %Event{} =
               found_event =
               EventStoreHelper.get_create_event_by_source(
                 event.source,
                 event.source_idempk,
                 instance.id
               )

      [processed_transaction | []] = found_event.transactions
      assert processed_transaction.id == transaction.id
    end

    test "returns nil for non-existent event", %{instance: instance} do
      assert nil ==
               EventStoreHelper.get_create_event_by_source("source", "source_idempk", instance.id)
    end
  end

  describe "claim_event_for_processing/2" do
    setup [:create_instance, :create_accounts]

    test "returns error when event not found" do
      assert {:error, :event_not_found} =
               EventStore.claim_event_for_processing(Ecto.UUID.generate(), "manual")
    end

    test "returns error when event not claimable", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))
      event |> Ecto.Changeset.change(%{status: :dead_letter}) |> Repo.update!()

      assert {:error, :event_not_claimable} =
               EventStore.claim_event_for_processing(event.id, "manual")
    end

    test "claims an event for processing", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{event_queue_item: eqm} = claimed_event} =
               EventStore.claim_event_for_processing(event.id, "manual")

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
               EventStore.claim_event_for_processing(
                 event.id,
                 "manual",
                 DoubleEntryLedger.MockRepo
               )
    end
  end
end
