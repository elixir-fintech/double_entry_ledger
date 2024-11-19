defmodule DoubleEntryLedger.EventWorker.EventMapTest do
  @moduledoc """
  This module tests the EventMap module.
  """
  use ExUnit.Case
  import Mox

  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  import DoubleEntryLedger.EventWorker.EventTransformer,
    only: [transaction_data_to_transaction_map: 2]

  alias DoubleEntryLedger.EventWorker.EventMap
  alias DoubleEntryLedger.Event

  doctest EventMap

  describe "process_map/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", ctx do
      event_map = event_map(ctx)

      {:ok, transaction, processed_event} = EventMap.process_map(event_map)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :pending
    end
  end

  describe "process_map_with_retry/2" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "with last retry that fails", ctx do
      %{transaction_data: td, instance_id: id} = event_map = event_map(ctx)
      {:ok, transaction_map} = transaction_data_to_transaction_map(td, id)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: changeset
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, :transaction, :occ_final_timeout, %Event{id: id}} =
               EventMap.process_map_with_retry(
                 event_map,
                 transaction_map,
                 %{errors: [], steps_so_far: %{}},
                 1,
                 DoubleEntryLedger.MockRepo
               )

      assert %Event{status: :occ_timeout} = Repo.get(Event, id)
    end
  end

  defp event_map(%{instance: %{id: id}, accounts: [a1, a2, _, _]}) do
    %{
      action: :create,
      instance_id: id,
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
  end
end
