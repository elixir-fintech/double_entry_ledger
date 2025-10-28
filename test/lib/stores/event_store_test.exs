defmodule DoubleEntryLedger.Stores.EventStoreTest do
  @moduledoc """
  This module tests the EventStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.Command

  alias DoubleEntryLedger.Stores.{
    EventStore,
    EventStoreHelper,
    AccountStore,
    InstanceStore,
    TransactionStore
  }

  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEvent

  doctest EventStoreHelper
  doctest EventStore

  describe "create/1" do
    setup [:create_instance]

    test "inserts a new event and adds an command_queue_item", %{instance: instance} do
      assert {:ok, %Command{id: id} = event} =
               EventStore.create(transaction_event_attrs(instance_address: instance.address))

      assert %{id: evq_id, event_id: ^id, status: :pending} = event.command_queue_item
      assert evq_id != nil
    end
  end

  describe "get_event_by/4" do
    setup [:create_instance, :create_accounts]

    test "gets an event by source", %{instance: instance} do
      {:ok, event} =
        EventStore.create(transaction_event_attrs(instance_address: instance.address))

      assert %Command{} =
               found_event =
               EventStoreHelper.get_event_by(
                 :create_transaction,
                 event.event_map.source,
                 event.event_map.source_idempk,
                 instance.id
               )

      assert found_event.id == event.id
    end

    test "returns processed_transaction", %{instance: instance} = ctx do
      %{event: %{event_map: event_map} = event} = new_create_transaction_event(ctx, :pending)
      {:ok, transaction, _} = CreateTransactionEvent.process(event)

      assert %Command{} =
               found_event =
               EventStoreHelper.get_event_by(
                 :create_transaction,
                 event_map.source,
                 event_map.source_idempk,
                 instance.id
               )

      [processed_transaction | []] = found_event.transactions
      assert processed_transaction.id == transaction.id
    end

    test "returns nil for non-existent event", %{instance: instance} do
      assert nil ==
               EventStoreHelper.get_event_by(
                 :create_transaction,
                 "source",
                 "source_idempk",
                 instance.id
               )
    end
  end
end
