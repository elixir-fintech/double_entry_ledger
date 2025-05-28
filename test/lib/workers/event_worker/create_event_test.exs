defmodule DoubleEntryLedger.CreateEventTest do
  @moduledoc """
  This module tests the CreateEvent module.
  """
  use ExUnit.Case
  import Mox

  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.EventWorker.CreateEvent

  doctest CreateEvent

  describe "process_create_event/2" do
    setup [:create_instance, :create_accounts]

    test "successful", ctx do
      %{event: event} = create_event(ctx)

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        CreateEvent.process_create_event(event)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "error when saving transaction", ctx do
      %{event: event} = create_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn _changeset ->
        # simulate a conflict when adding the transaction
        {:error, :conflict}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the epo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{} = error_event} =
               CreateEvent.process_create_event(event, DoubleEntryLedger.MockRepo)

      assert error_event.status == :failed

      assert [%{message: "CreateEvent: Step :transaction failed. Error: :conflict"} | _] =
               error_event.errors
    end

    test "occ timeout", ctx do
      %{event: event} = create_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        Repo.transaction(multi)
        # the transaction has to be handled by the Repo
      end)

      {:error, %{event_queue_item: eqm} = updated_event} =
        CreateEvent.process_create_event(event, DoubleEntryLedger.MockRepo)

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
