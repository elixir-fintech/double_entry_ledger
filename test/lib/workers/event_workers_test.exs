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
  alias DoubleEntryLedger.EventStore
  alias DoubleEntryLedger.Event

  doctest EventWorker

  describe "EventWorker" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      {:ok, event} = create_event(ctx)

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

    test "retry for 0 attempts left" do
      assert {:error, "OCC conflict: Max number of 2 retries reached"  } = EventWorker.retry({}, 0, {%{}, %{}})
    end

    test "retry for 1 attempt left", ctx do
      {:ok, event} = create_event(ctx)

      func = fn _event, _map ->
        raise Ecto.StaleEntryError,
          action: :update,
          changeset: %{data: ""}
        end
      assert {:error, "OCC conflict: Max number of 2 retries reached"  } = EventWorker.retry(func, 1, {event, %{}})
      assert [%{"message" => "OCC conflict detected, retrying after 20 ms... 0 attempts left"}] = Repo.reload(event).errors
    end

    test "retry for 2 accumulates errors", ctx do
      {:ok, event} = create_event(ctx)

      func = fn _event, _map ->
        raise Ecto.StaleEntryError,
          action: :update,
          changeset: %{data: ""}
        end
      assert {:error, "OCC conflict: Max number of 2 retries reached"  } = EventWorker.retry(func, 2, {event, %{}})
      assert [
        %{"message" => "OCC conflict detected, retrying after 20 ms... 0 attempts left"},
        %{"message" => "OCC conflict detected, retrying after 10 ms... 1 attempts left"}] = Repo.reload(event).errors
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

  defp create_event(%{instance: inst, accounts: [a1, a2, _, _] }) do
    EventStore.insert_event(event_attrs(
      instance_id: inst.id,
      transaction_data: %{
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
  end
end
