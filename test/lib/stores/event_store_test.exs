defmodule DoubleEntryLedger.EventStoreTest do
  @moduledoc """
  This module tests the EventStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.TransactionFixtures
  alias DoubleEntryLedger.{EventStore, Event, TransactionStore}

  describe "insert_event/1" do
    setup [:create_instance]
    test "inserts a new event", %{instance: instance} do
      assert {:ok, %Event{} = event} = EventStore.insert_event(event_attrs(instance_id: instance.id))
      assert event.status == :pending
      assert event.processed_at == nil
    end
  end

  describe "build_mark_as_processed/1" do
    setup [:create_instance, :create_accounts, :create_transaction]
    test "marks an event as processed", %{instance: instance, transaction: transaction} do
      {:ok, event} = EventStore.insert_event(event_attrs(instance_id: instance.id))
      assert {:ok, %Event{} = updated_event} =
        EventStore.build_mark_as_processed(event, transaction.id)
        |> Repo.update()
      assert updated_event.status == :processed
      assert updated_event.processed_at != nil
      assert updated_event.processed_transaction_id == transaction.id
    end
  end

  describe "mark_as_failed/2" do
    setup [:create_instance]
    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.insert_event(event_attrs(instance_id: instance.id))
      assert {:ok, %Event{} = updated_event} =
        EventStore.mark_as_failed(event, "some reason")
      assert updated_event.status == :failed
      assert updated_event.processed_at == nil

      assert [%{message: "some reason"} | _ ] = updated_event.errors
    end
  end

  describe "add_error/2" do
    setup [:create_instance]
    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.insert_event(event_attrs(instance_id: instance.id))
      assert {:ok, %Event{} = updated_event} =
        EventStore.add_error(event, "some reason")
      assert updated_event.status == :pending
      assert updated_event.processed_at == nil
      assert [%{message: "some reason"} | _ ] = updated_event.errors
    end
  end

  describe "add_error/2 accumulates errors" do
    setup [:create_instance]
    test "marks an event as failed", %{instance: instance} do
      {:ok, event} = EventStore.insert_event(event_attrs(instance_id: instance.id))
      {:ok, event1} = EventStore.add_error(event, "reason1")
      {:ok, updated_event} = EventStore.add_error(event1, "reason2")
      assert updated_event.status == :pending
      assert updated_event.processed_at == nil
      assert [%{message: "reason2"}, %{message: "reason1"}] = updated_event.errors
    end
  end


  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end

  defp create_accounts(%{instance: instance}) do
    %{instance: instance, accounts: [
      account_fixture(instance_id: instance.id, type: :debit),
      account_fixture(instance_id: instance.id, type: :credit),
    ]}
  end

  defp create_transaction(%{instance: instance, accounts: [acc1, acc2] = accounts}) do
    transaction = transaction_attr(instance_id: instance.id, entries: [
      %{type: :debit, amount: Money.new(100, :EUR), account_id:  acc1.id},
      %{type: :credit, amount: Money.new(100, :EUR), account_id:  acc2.id}
    ])
    {:ok, transaction} = TransactionStore.create(transaction)
    %{instance: instance, transaction: transaction, accounts: accounts}
  end
end
