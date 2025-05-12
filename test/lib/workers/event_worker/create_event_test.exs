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
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end
  end

  describe "process_attempt/2" do
    setup [:create_instance, :create_accounts]

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

      assert {:ok, {:error, :transaction, :conflict, %{}}} =
               CreateEvent.process_attempt(event, DoubleEntryLedger.MockRepo)
    end

    test "occ timeout", ctx do
      %{event: event} = create_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn _changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)
      |> expect(:update!, 7, fn changeset ->
        Repo.update!(changeset)
        # simulate a conflict when adding the transaction
      end)
      |> expect(:transaction, 5, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      {:ok, {:error, :transaction, :occ_final_timeout, updated_event}} =
        CreateEvent.process_attempt(event, DoubleEntryLedger.MockRepo)

      assert updated_event.status == :occ_timeout
      assert updated_event.occ_retry_count == 5
      assert updated_event.processed_transaction_id == nil
      assert updated_event.processed_at == nil
      assert length(updated_event.errors) == 5
      assert updated_event.retry_count == 0
      assert updated_event.next_retry_after == nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               updated_event.errors
    end
  end
end
