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

  describe "process_create_event/1" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      %{event: event} = create_event(ctx)

      {:ok, transaction, processed_event} = CreateEvent.process_create_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end

    test "process create event with error when saving transaction", ctx do
      %{event: event} = create_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn _changeset ->
        # simulate a conflict when adding the transaction
        {:error, :conflict}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{} = event} =
               CreateEvent.process_create_event(event, DoubleEntryLedger.MockRepo)

      assert event.status == :failed
    end

    test "process event with occ timeout", ctx do
      %{event: event} = create_event(ctx)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn _changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)
      |> expect(:transaction, 5, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      {:error, updated_event} = CreateEvent.process_create_event(event, DoubleEntryLedger.MockRepo)
      assert updated_event.status == :occ_timeout
      assert updated_event.occ_retry_count == 6
      IO.puts("ERROR: #{inspect(updated_event.errors)}")
      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] = updated_event.errors
    end
  end
end
