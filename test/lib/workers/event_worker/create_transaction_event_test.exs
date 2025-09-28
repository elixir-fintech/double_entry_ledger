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

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Workers.EventWorker.CreateTransactionEvent

  doctest CreateTransactionEvent

  describe "process_create_event/2" do
    setup [:create_instance, :create_accounts]

    test "successful", ctx do
      %{event: event} = new_create_transaction_event(ctx)

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        CreateTransactionEvent.process(event)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "error when saving transaction", ctx do
      %{event: event} = new_create_transaction_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn _changeset ->
        # simulate a conflict when adding the transaction
        {:error, :conflict}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the epo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{event_queue_item: eqm}} =
               CreateTransactionEvent.process(event, DoubleEntryLedger.MockRepo)

      assert eqm.status == :failed

      assert [
               %{message: "CreateTransactionEvent: Step :transaction failed. Error: :conflict"}
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

      {:error, %{event_queue_item: eqm} = updated_event} =
        CreateTransactionEvent.process(event, DoubleEntryLedger.MockRepo)

      %{transactions: []} = Repo.preload(updated_event, :transactions)
      assert eqm.processing_completed_at != nil
      assert eqm.occ_retry_count == 5
      assert eqm.retry_count == 1
      assert eqm.next_retry_after != nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               eqm.errors
    end
  end
end
