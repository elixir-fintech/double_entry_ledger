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

      {:ok, transaction, processed_event} = CreateEvent.process_create_event(event)
      assert processed_event.status == :processed

      %{transactions: [processed_transaction | []]} =
        processed_event = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert processed_event.processed_at != nil
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

      {:error, updated_event} =
        CreateEvent.process_create_event(event, DoubleEntryLedger.MockRepo)

      %{transactions: []} = updated_event = Repo.preload(updated_event, :transactions)
      assert updated_event.processed_at == nil
      assert updated_event.occ_retry_count == 5
      assert updated_event.retry_count == 1
      assert updated_event.next_retry_after != nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               updated_event.errors
    end
  end
end
