defmodule DoubleEntryLedger.EventProcessorTest do
  @moduledoc """
  This module tests the EventProcessor.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.EventProcessor
  alias DoubleEntryLedger.EventStore
  alias DoubleEntryLedger.Event

  doctest EventProcessor

  describe "EventProcessor" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", %{instance: inst, accounts: [a1, a2, _, _]} do
      {:ok, event} = EventStore.insert_event(event_attrs(
        transaction_data: %{
          instance_id: inst.id,
          status: :posted,
          entries: [
            %{
              account_id: a1.id,
              amount: 100,
              currency: "EUR"
            },
            %{
              account_id: a2.id,
              amount: 100,
              currency: "EUR"
            }
          ]
        }
      ))

      {:ok, transaction, processed_event } = EventProcessor.process_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end

    test "only process pending events" do
      assert {:error, "Event is not in pending state"} = EventProcessor.process_event(%Event{status: :processed})
      assert {:error, "Event is not in pending state"} = EventProcessor.process_event(%Event{status: :failed})
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end

  defp create_accounts(%{instance: instance}) do
    %{instance: instance, accounts: [
      account_fixture(instance_id: instance.id, type: :debit),
      account_fixture(instance_id: instance.id, type: :credit),
      account_fixture(instance_id: instance.id, type: :debit),
      account_fixture(instance_id: instance.id, type: :credit)
    ]}
  end
end
