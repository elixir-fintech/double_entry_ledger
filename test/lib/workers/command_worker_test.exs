defmodule DoubleEntryLedger.Workers.CommandWorkerTest do
  @moduledoc """
  This module tests the CommandWorker.
  """
  use ExUnit.Case
  alias DoubleEntryLedger.Command.TransactionEventMap
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Stores.EventStore

  alias DoubleEntryLedger.Workers.CommandWorker

  doctest CommandWorker

  describe "process_event_with_id/1" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      %{event: event} = new_create_transaction_event(ctx)

      {:ok, transaction, %{command_queue_item: evq} = processed_event} =
        CommandWorker.process_event_with_id(event.id)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = EventStore.get_by_id(processed_event.id)

      assert return_available_balances(ctx) == [100, 100]
      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "update event for changing entries and to :posted",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, %{event_map: %{source: s, source_idempk: s_id}}} =
        CommandWorker.process_event_with_id(pending_event.id)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        new_update_transaction_event(s, s_id, inst.address, :posted, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, %{command_queue_item: evq} = processed_event} =
        CommandWorker.process_event_with_id(event.id)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = EventStore.get_by_id(processed_event.id)

      assert processed_transaction.id == pending_transaction.id
      assert transaction.id == pending_transaction.id
      assert evq.processing_completed_at != nil
      assert return_available_balances(ctx) == [50, 50]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "don't process events with status [:processed, :dead_letter]", ctx do
      %{event: event} = new_create_transaction_event(ctx)
      CommandWorker.process_event_with_id(event.id)

      assert {:error, :event_not_claimable} =
               CommandWorker.process_event_with_id(event.id)

      event
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(
        :command_queue_item,
        %{id: event.command_queue_item.id, status: :dead_letter}
      )
      |> Repo.update!()

      assert {:error, :event_not_claimable} =
               CommandWorker.process_event_with_id(event.id)
    end
  end

  describe "process_event_map/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", %{
      instance: inst,
      accounts: [a1, a2, _, _]
    } do
      {:ok, event_map} =
        %{
          action: :create_transaction,
          instance_address: inst.address,
          source: "source",
          source_data: %{},
          source_idempk: "source_idempk",
          update_idempk: nil,
          payload: %{
            status: :pending,
            entries: [
              %{account_address: a1.address, amount: 100, currency: "EUR"},
              %{account_address: a2.address, amount: 100, currency: "EUR"}
            ]
          }
        }
        |> TransactionEventMap.create()

      {:ok, transaction, %{command_queue_item: evq} = processed_event} =
        CommandWorker.process_new_event(event_map)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :pending
    end
  end
end
