defmodule DoubleEntryLedger.EventWorkerTest do
  @moduledoc """
  This module tests the EventWorker.
  """
  use ExUnit.Case
  alias DoubleEntryLedger.Event.EventMap
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{
    EventStore,
    EventWorker
  }

  doctest EventWorker

  describe "process_event_with_id/1" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      %{event: event} = create_event(ctx)

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        EventWorker.process_event_with_id(event.id)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "update event for changing entries and to :posted",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        EventWorker.process_event_with_id(pending_event.id)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :posted, [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        EventWorker.process_event_with_id(event.id)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == pending_transaction.id
      assert transaction.id == pending_transaction.id
      assert evq.processing_completed_at != nil
      assert return_available_balances(ctx) == [50, 50]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "don't process events with status [:processed, :dead_letter]", ctx do
      %{event: event} = create_event(ctx)
      EventWorker.process_event_with_id(event.id)

      assert {:error, :event_not_claimable} =
               EventWorker.process_event_with_id(event.id)

      event |> Ecto.Changeset.change(%{status: :dead_letter}) |> Repo.update!()

      assert {:error, :event_not_claimable} =
               EventWorker.process_event_with_id(event.id)
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
          action: :create,
          instance_id: inst.id,
          source: "source",
          source_data: %{},
          source_idempk: "source_idempk",
          update_idempk: nil,
          transaction_data: %{
            status: :pending,
            entries: [
              %{account_id: a1.id, amount: 100, currency: "EUR"},
              %{account_id: a2.id, amount: 100, currency: "EUR"}
            ]
          }
        }
        |> EventMap.create()

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        EventWorker.process_new_event(event_map)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :pending
    end
  end
end
