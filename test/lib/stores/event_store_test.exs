defmodule DoubleEntryLedger.EventStoreTest do
  @moduledoc """
  This module tests the EventStore module.
  """
  use ExUnit.Case, async: true
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
      assert event.tries == 0
    end
  end

  describe "build_mark_as_processed/1" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "marks an event as processed", %{instance: instance, transaction: transaction} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{} = updated_event} =
               EventStoreHelper.build_mark_as_processed(event, transaction.id)
               |> Repo.update()

      assert updated_event.status == :processed
      assert updated_event.processed_at != nil
      assert updated_event.processed_transaction_id == transaction.id
      assert updated_event.tries == 1
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
      assert updated_event.tries == 1

      assert [%{message: "some reason"} | _] = updated_event.errors
    end
  end

  describe "add_error/2" do
    setup [:create_instance]

    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{} = updated_event} =
               EventStore.add_error(event, "some reason")

      assert updated_event.status == :pending
      assert updated_event.processed_at == nil
      assert updated_event.tries == 1
      assert [%{message: "some reason"} | _] = updated_event.errors
    end
  end

  describe "add_error/2 accumulates errors" do
    setup [:create_instance]

    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))
      {:ok, event1} = EventStore.add_error(event, "reason1")
      {:ok, updated_event} = EventStore.add_error(event1, "reason2")
      assert updated_event.status == :pending
      assert updated_event.processed_at == nil
      assert updated_event.tries == 2
      assert [%{message: "reason2"}, %{message: "reason1"}] = updated_event.errors
    end
  end

  describe "mark_as_occ_timeout" do
    setup [:create_instance]

    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.create(event_attrs(instance_id: instance.id))

      assert {:ok, %Event{} = updated_event} =
               EventStore.mark_as_occ_timeout(event, "some reason")

      assert updated_event.status == :occ_timeout
      assert updated_event.processed_at == nil
      assert updated_event.tries == 1
      assert [%{message: "some reason"} | _] = updated_event.errors
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
      {:ok, {transaction, _}} = CreateEvent.process_create_event(event)

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
end
