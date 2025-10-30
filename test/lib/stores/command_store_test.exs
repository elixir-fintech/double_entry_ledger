defmodule DoubleEntryLedger.Stores.EventStoreTest do
  @moduledoc """
  This module tests the CommandStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.Command

  alias DoubleEntryLedger.Stores.{
    CommandStore,
    CommandStoreHelper,
    AccountStore,
    InstanceStore,
    TransactionStore
  }

  alias DoubleEntryLedger.Command.TransactionEventMap

  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEvent

  doctest CommandStoreHelper
  doctest CommandStore

  describe "create/1" do
    setup [:create_instance]

    test "inserts a new event and adds an command_queue_item", %{instance: instance} do
      assert {:ok, %Command{id: id} = event} =
               CommandStore.create(transaction_event_attrs(instance_address: instance.address))

      assert %{id: evq_id, command_id: ^id, status: :pending} = event.command_queue_item
      assert evq_id != nil
    end

    test "fails for invalid instance_address" do
      trx_map = transaction_event_attrs(instance_address: "1234", action: :create_transaction)

      assert {:error, %Ecto.Changeset{errors: errors}} = CommandStore.create(trx_map)
      assert Keyword.has_key?(errors, :instance_id)
    end

    test "fails when adding identical command with action: create_transaction", %{
      instance: %{address: address}
    } do
      trx_map = transaction_event_attrs(instance_address: address, action: :create_transaction)
      assert {:ok, %Command{} = _event} = CommandStore.create(trx_map)
      assert {:error, :pending_transaction_idempotency_violation} = CommandStore.create(trx_map)
    end
  end

  describe "get_event_by/4" do
    setup [:create_instance, :create_accounts]

    test "gets an event by source", %{instance: instance} do
      {:ok, event} =
        CommandStore.create(transaction_event_attrs(instance_address: instance.address))

      assert %Command{} =
               found_event =
               CommandStoreHelper.get_event_by(
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
               CommandStoreHelper.get_event_by(
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
               CommandStoreHelper.get_event_by(
                 :create_transaction,
                 "source",
                 "source_idempk",
                 instance.id
               )
    end
  end
end
