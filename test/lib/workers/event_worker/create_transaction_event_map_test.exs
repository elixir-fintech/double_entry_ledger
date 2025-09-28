defmodule DoubleEntryLedger.Workers.EventWorker.CreateTransactionEventMapTest do
  @moduledoc """
  This module tests the CreateTransactionEventMap module, which processes event maps for atomic creation and update of events and their associated transactions. It ensures correct OCC handling, error mapping, and transactional guarantees.
  """
  use ExUnit.Case
  import Mox

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.TransactionEventMap, as: TransactionEventMapSchema
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Workers.EventWorker.CreateTransactionEventMap
  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.EventStore

  doctest CreateTransactionEventMap

  describe "process_map/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", ctx do
      event_map = create_transaction_event_map(ctx)

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        CreateTransactionEventMap.process(event_map)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :pending
    end

    test "return TransactionEventMap changeset for duplicate source_idempk", ctx do
      # successfully create event
      event_map = create_transaction_event_map(ctx)
      CreateTransactionEventMap.process(event_map)

      # process same event_map again which should fail
      {:error, changeset} = CreateTransactionEventMap.process(event_map)
      assert %Changeset{data: %TransactionEventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :source_idempk)
    end

    test "return TransactionEventMap changeset for other errors", ctx do
      # successfully create event
      event_map = create_transaction_event_map(ctx, :pending)

      updated_event_map =
        update_in(
          event_map,
          [Access.key!(:payload), Access.key!(:entries), Access.at(1), Access.key!(:currency)],
          fn _ ->
            "USD"
          end
        )

      # process same update_event again which should fail
      {:error, changeset} =
        CreateTransactionEventMap.process(updated_event_map)

      assert %Changeset{data: %TransactionEventMapSchema{}} = changeset
    end
  end

  describe "process_map/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{id: id, event_queue_item: %{status: :occ_timeout}}} =
               CreateTransactionEventMap.process(
                 create_transaction_event_map(ctx),
                 DoubleEntryLedger.MockRepo
               )

      assert %Event{
               event_queue_item: %{status: :occ_timeout, occ_retry_count: 5, errors: errors},
               transactions: []
             } =
               EventStore.get_by_id(id) |> Repo.preload(:transactions)

      assert length(errors) == 5
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = errors
    end
  end
end
