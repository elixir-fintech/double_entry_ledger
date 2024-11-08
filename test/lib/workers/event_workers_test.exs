defmodule DoubleEntryLedger.EventWorkerTest do
  @moduledoc """
  This module tests the EventWorker.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.EventWorker
  alias DoubleEntryLedger.Event

  doctest EventWorker

  describe "process_event/1" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      %{event: event} = create_event(ctx)

      {:ok, transaction, processed_event } = EventWorker.process_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end

    test "process update event successfully for changing entries and to :posted", %{instance: inst, accounts: [a1, a2| _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} = EventWorker.process_event(pending_event)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted, [
        %{account_id: a1.id, amount: 50, currency: "EUR" },
        %{account_id: a2.id, amount: 50, currency: "EUR" }
      ])

      {:ok, transaction, processed_event } = EventWorker.process_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == pending_transaction.id
      assert transaction.id == pending_transaction.id
      assert processed_event.processed_at != nil
      assert return_available_balances(ctx) == [50, 50]
      assert transaction.status == :posted
    end

    test "only process pending events" do
      assert {:error, "Event is not in pending state"} = EventWorker.process_event(%Event{status: :processed})
      assert {:error, "Event is not in pending state"} = EventWorker.process_event(%Event{status: :failed})
    end
  end
end
