defmodule DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEventMapTest do
  @moduledoc """
  This module tests the CreateTransactionEventMap module, which processes event maps for atomic creation and update of events and their associated transactions. It ensures correct OCC handling, error mapping, and transactional guarantees.
  """
  use ExUnit.Case
  import Mox

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.{TransactionEventMap, TransactionData, EntryData}
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEventMap
  alias DoubleEntryLedger.{Command, PendingTransactionLookup}
  alias DoubleEntryLedger.Stores.CommandStore

  doctest CreateTransactionEventMap

  describe "process_map/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", ctx do
      event_map = create_transaction_event_map(ctx)

      {:ok, transaction, %{command_queue_item: evq} = processed_event} =
        CreateTransactionEventMap.process(event_map)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :pending
    end

    test "pending transaction also creates a pending transaction lookup", ctx do
      event_map = create_transaction_event_map(ctx, :pending)

      {:ok, %{id: trx_id}, %{id: id}} = CreateTransactionEventMap.process(event_map)

      assert %{command_id: ^id, transaction_id: ^trx_id} =
               Repo.get_by(PendingTransactionLookup, command_id: id)
    end

    test "posted transaction don't create a pending transaction lookup", ctx do
      event_map = create_transaction_event_map(ctx, :posted)

      {:ok, _, %{id: id}} = CreateTransactionEventMap.process(event_map)
      assert is_nil(Repo.get_by(PendingTransactionLookup, command_id: id))
    end

    test "return TransactionEventMap changeset for duplicate source_idempk", ctx do
      # successfully create event
      event_map = create_transaction_event_map(ctx)
      CreateTransactionEventMap.process(event_map)

      # process same event_map again which should fail
      {:error, changeset} = CreateTransactionEventMap.process(event_map)
      assert %Changeset{data: %TransactionEventMap{}} = changeset
      assert Keyword.has_key?(changeset.errors, :key_hash)
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

      {:error, changeset} =
        CreateTransactionEventMap.process(updated_event_map)

      assert %Changeset{data: %TransactionEventMap{}} = changeset
    end

    test "return TransactionEventMap for transaction_map error", %{
      instance: inst,
      accounts: [a | _]
    } do
      event_map =
        transaction_event_attrs(
          instance_address: inst.address,
          payload: %TransactionData{
            status: :posted,
            entries: [
              %EntryData{account_address: a.address, amount: 100, currency: "EUR"},
              %EntryData{account_address: "nonexisting:account", amount: 100, currency: "EUR"}
            ]
          }
        )

      {:error, changeset} =
        CreateTransactionEventMap.process(event_map)

      assert %Changeset{data: %TransactionEventMap{}} = changeset
    end
  end

  describe "process/2 with OCC timeout" do
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

      assert {:error, %Command{id: id, command_queue_item: %{status: :occ_timeout}}} =
               CreateTransactionEventMap.process(
                 create_transaction_event_map(ctx, :pending),
                 DoubleEntryLedger.MockRepo
               )

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5, errors: errors},
               transactions: []
             } =
               CommandStore.get_by_id(id) |> Repo.preload(:transactions)

      assert length(errors) == 5
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = errors
    end

    test "creates a pending_transaction_lookup for commands with pending status", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi -> Repo.transaction(multi) end)

      {:error, %Command{id: id}} =
        CreateTransactionEventMap.process(
          create_transaction_event_map(ctx, :pending),
          DoubleEntryLedger.MockRepo
        )

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5}
             } =
               CommandStore.get_by_id(id)

      assert %{command_id: ^id} = Repo.get_by(PendingTransactionLookup, command_id: id)
    end

    test "does not create a pending_transaction_lookup for other commands", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi -> Repo.transaction(multi) end)

      {:error, %Command{id: id}} =
        CreateTransactionEventMap.process(
          create_transaction_event_map(ctx, :posted),
          DoubleEntryLedger.MockRepo
        )

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5}
             } =
               CommandStore.get_by_id(id)

      assert is_nil(Repo.get_by(PendingTransactionLookup, command_id: id))
    end
  end
end
