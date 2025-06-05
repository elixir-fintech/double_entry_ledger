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
  alias DoubleEntryLedger.{EventStore, EventStoreHelper, Event}
  alias DoubleEntryLedger.EventWorker.CreateEvent

  describe "create/1" do
    setup [:create_instance]

    test "inserts a new event and adds an event_queue_item", %{instance: instance} do
      assert {:ok, %Event{id: id} = event} =
               EventStore.create(event_attrs(instance_id: instance.id))

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
      {:ok, transaction, _} = CreateEvent.process(event)

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
end
