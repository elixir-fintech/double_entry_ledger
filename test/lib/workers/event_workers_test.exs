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

    test "only process pending events" do
      assert {:error, "Event is not in pending state"} = EventWorker.process_event(%Event{status: :processed})
      assert {:error, "Event is not in pending state"} = EventWorker.process_event(%Event{status: :failed})
    end
  end
end
