defmodule DoubleEntryLedger.CreateTransactionEventTest do
  @moduledoc """
  This module tests the CreateTransactionEvent module.
  """
  use ExUnit.Case
  import Mox

  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{Command, PendingTransactionLookup}
  alias DoubleEntryLedger.Command.TransactionData
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEvent

  doctest CreateTransactionEvent

  describe "process_create_event/2" do
    setup [:create_instance, :create_accounts]

    test "successful fro posted transaction", ctx do
      %{event: event} = new_create_transaction_event(ctx)

      {:ok, transaction, %{id: id, command_queue_item: evq} = processed_event} =
        CreateTransactionEvent.process(event)

      assert evq.status == :processed

      %{transaction: %{id: trx_id} = processed_transaction} =
        Repo.preload(processed_event, :transaction)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
      assert is_nil(Repo.get_by(PendingTransactionLookup, command_id: id))
    end

    test "pending transaction also updates the pending transaction lookup", ctx do
      %{event: event} = new_create_transaction_event(ctx, :pending)

      {:ok, transaction, %{id: id, command_queue_item: evq} = processed_event} =
        CreateTransactionEvent.process(event)

      assert evq.status == :processed

      %{transaction: %{id: trx_id} = processed_transaction} =
        Repo.preload(processed_event, :transaction)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :pending

      assert %{command_id: ^id, transaction_id: ^trx_id} =
               Repo.get_by(PendingTransactionLookup, command_id: id)
    end

    test "fails for transaction_map_error due to non existent account", %{
      instance: inst,
      accounts: [a | _]
    } do
      {:ok, event} =
        CommandStore.create(
          transaction_event_attrs(
            instance_address: inst.address,
            payload: %TransactionData{
              status: :posted,
              entries: [
                %{account_address: a.address, amount: 100, currency: "EUR"},
                %{account_address: "nonexisting:account", amount: 100, currency: "EUR"}
              ]
            }
          )
        )

      assert {:error, %Command{command_queue_item: eqm}} = CreateTransactionEvent.process(event)
      assert eqm.status == :dead_letter
    end

    test "error when saving transaction", ctx do
      %{event: event} = new_create_transaction_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn changeset ->
        # simulate a conflict when adding the transaction
        {:error, Ecto.Changeset.add_error(changeset, :entries, ":conflict")}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the epo
        Repo.transaction(multi)
      end)

      assert {:error, %Command{command_queue_item: eqm}} =
               CreateTransactionEvent.process(event, DoubleEntryLedger.MockRepo)

      assert eqm.status == :dead_letter

      assert [
               %{
                 message:
                   "TransactionEventResponseHandler: Transaction changeset failed %{entries: [\":conflict\"]}"
               }
               | _
             ] =
               eqm.errors
    end

    test "occ timeout", ctx do
      %{event: event} = new_create_transaction_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        Repo.transaction(multi)
        # the transaction has to be handled by the Repo
      end)

      {:error, %{command_queue_item: eqm} = updated_event} =
        CreateTransactionEvent.process(event, DoubleEntryLedger.MockRepo)

      %{transaction: nil} = Repo.preload(updated_event, :transaction)
      assert eqm.processing_completed_at != nil
      assert eqm.occ_retry_count == 5
      assert eqm.retry_count == 0
      assert eqm.next_retry_after != nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               eqm.errors
    end
  end
end
