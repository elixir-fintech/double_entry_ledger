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
  import DoubleEntryLedger.TransactionFixtures
  alias DoubleEntryLedger.{EventStore, EventStoreHelper, Event}
  alias DoubleEntryLedger.EventWorker.CreateEvent

  describe "create/1" do
    setup [:create_instance]

    test "inserts a new event", %{instance: instance} do
      assert {:ok, %Event{} = event} = EventStore.create(event_attrs(instance_id: instance.id))
      assert event.status == :pending
      assert event.processed_at == nil
      assert event.occ_retry_count == 0
    end
  end

  describe "mark_as_failed/2" do
    setup [:create_instance]

    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{} = updated_event} =
               EventStore.mark_as_failed(event, "some reason")

      assert updated_event.status == :failed
      assert updated_event.processed_at == nil

      assert [%{message: "some reason"} | _] = updated_event.errors
    end
  end

  describe "add_error/2" do
    setup [:create_instance]

    test "adds an error to an event", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{} = updated_event} =
               EventStore.add_error(event, "some reason")

      assert updated_event.status == :pending
      assert updated_event.processed_at == nil
      assert [%{message: "some reason"} | _] = updated_event.errors
    end

    test "add_error/2 accumulates errors", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))
      {:ok, event1} = EventStore.add_error(event, "reason1")
      {:ok, updated_event} = EventStore.add_error(event1, "reason2")
      assert updated_event.status == :pending
      assert updated_event.processed_at == nil
      assert [%{message: "reason2"}, %{message: "reason1"}] = updated_event.errors
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

      assert found_event.processed_transaction.id == transaction.id
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
               EventStore.claim_event_for_processing(Ecto.UUID.generate())
    end

    test "returns error when event not claimable", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      EventStore.mark_as_failed(event, "some reason")

      assert {:error, :event_not_claimable} =
               EventStore.claim_event_for_processing(event.id)
    end

    test "claims an event for processing", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{} = claimed_event} =
               EventStore.claim_event_for_processing(event.id)

      assert claimed_event.status == :processing
      assert claimed_event.processor_id == "manual"
    end

    test "returns an error when stale entry error occurs", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :event_not_claimable} =
               EventStore.claim_event_for_processing(
                 event.id,
                 "manual",
                 DoubleEntryLedger.MockRepo
               )
    end
  end
end
