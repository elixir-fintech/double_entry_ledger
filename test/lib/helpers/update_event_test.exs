defmodule DoubleEntryLedger.UpdateEventTest do
  @moduledoc """
  This module tests the CreateEvent module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{UpdateEvent, CreateEvent, EventStore}

  doctest CreateEvent

  describe "process_update_event/1" do
    setup [:create_instance, :create_accounts]

    test "process update event successfully for simple update to posted", %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, %{source: s, source_id: s_id}} = CreateEvent.process_create_event(pending_event)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:ok, transaction, processed_event } = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [100, 100]
      assert transaction.status == :posted
    end

    test "process update event successfully for simple update to :archived", %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, %{source: s, source_id: s_id}} = CreateEvent.process_create_event(pending_event)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :archived)

      {:ok, transaction, processed_event } = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "process update event successfully for changing entries and to :posted", %{instance: inst, accounts: [a1, a2| _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, %{source: s, source_id: s_id}} = CreateEvent.process_create_event(pending_event)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted, [
        %{account_id: a1.id, amount: 50, currency: "EUR" },
        %{account_id: a2.id, amount: 50, currency: "EUR" }
      ])

      {:ok, transaction, processed_event } = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [50, 50]
      assert transaction.status == :posted
    end

    test "process update event successfully for changing entries and to :pending", %{instance: inst, accounts: [a1, a2| _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, %{source: s, source_id: s_id}} = CreateEvent.process_create_event(pending_event)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :pending, [
        %{account_id: a1.id, amount: 50, currency: "EUR" },
        %{account_id: a2.id, amount: 50, currency: "EUR" }
      ])

      {:ok, transaction, processed_event } = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [-50, -50]
      assert transaction.status == :pending
    end

    test "process update event successfully to :archived", %{instance: inst, accounts: [a1, a2| _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, %{source: s, source_id: s_id}} = CreateEvent.process_create_event(pending_event)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :archived, [
        %{account_id: a1.id, amount: 50, currency: "EUR" },
        %{account_id: a2.id, amount: 50, currency: "EUR" }
      ])

      {:ok, transaction, processed_event } = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "fails when create event does not exist", %{instance: inst} do
      {:ok, event} = create_update_event("source", "1", inst.id, :posted)

      assert {:error, "Create Event not found for Update Event (id: #{event.id})" } == UpdateEvent.process_update_event(event)
    end

    test "fails when create event is still pending", %{instance: inst} = ctx do
      %{event: %{id: e_id, source: s, source_id: s_id}} = create_event(ctx, :pending)
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      assert {:error, "Create event (id: #{e_id}) has not yet been processed"} == UpdateEvent.process_update_event(event)
    end

    test "fails when update event failed", %{instance: inst} = ctx do
      %{event: %{source: s, source_id: s_id} = pending_event} = create_event(ctx, :pending)
      EventStore.mark_as_failed(pending_event, "some reason")
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      assert {:error, "Create event (id: #{pending_event.id}) has failed for Update Event (id: #{event.id})"}
        == UpdateEvent.process_update_event(event)
    end
  end

  defp create_update_event(source, source_id, instance_id, trx_status, entries \\ []) do
    event_attrs(%{
      action: :update,
      source: source,
      source_id: source_id,
      instance_id: instance_id,
      transaction_data: %{
        status: trx_status,
        entries: entries
      }
    }) |> EventStore.insert_event()
  end

  defp shared_event_asserts(transaction, processed_event, pending_transaction) do
    assert processed_event.status == :processed
    assert processed_event.processed_transaction_id == pending_transaction.id
    assert transaction.id == pending_transaction.id
    assert processed_event.processed_at != nil
  end
end
