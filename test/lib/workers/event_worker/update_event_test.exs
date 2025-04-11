defmodule DoubleEntryLedger.UpdateEventTest do
  @moduledoc """
  This module tests the CreateEvent module.
  """
  use ExUnit.Case
  import Mox

  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{Event, EventStore}
  alias DoubleEntryLedger.EventWorker.{UpdateEvent, CreateEvent}

  doctest UpdateEvent

  describe "process_update_event/1" do
    setup [:create_instance, :create_accounts]

    test "process update event successfully for simple update to posted",
         %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [100, 100]
      assert transaction.status == :posted
    end

    test "process update event successfully for simple update to :archived",
         %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :archived)

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "process update event successfully for changing entries and to :posted",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :posted, [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [50, 50]
      assert transaction.status == :posted
    end

    test "process update event successfully for changing entries and to :pending",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :pending, [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [-50, -50]
      assert transaction.status == :pending
    end

    test "process update event successfully to :archived",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [-100, -100]

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :archived, [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "fails when create event does not exist", %{instance: inst} do
      {:ok, event} = create_update_event("source", "1", inst.id, :posted)

      {:error, failed_event} = UpdateEvent.process_update_event(event)
      assert failed_event.status == :failed

      [error | _] = failed_event.errors

      assert error.message ==
               "Create Event not found for Update Event (id: #{event.id})"
    end

    test "fails when create event is still pending", %{instance: inst} = ctx do
      %{event: %{id: e_id, source: s, source_idempk: s_id}} = create_event(ctx, :pending)
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:error, failed_event} = UpdateEvent.process_update_event(event)
      assert failed_event.status == :pending

      [error | _] = failed_event.errors

      assert error.message ==
               "Create event (id: #{e_id}) has not yet been processed for Update Event (id: #{event.id})"
    end

    test "fails when update event failed", %{instance: inst} = ctx do
      %{event: %{source: s, source_idempk: s_id} = pending_event} = create_event(ctx, :pending)
      EventStore.mark_as_failed(pending_event, "some reason")
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:error, failed_event} = UpdateEvent.process_update_event(event)
      assert failed_event.status == :failed

      [error | _] = failed_event.errors

      assert error.message ==
               "Create event (id: #{pending_event.id}) has failed for Update Event (id: #{event.id})"
    end

    test "update event with last retry that fails", %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, _pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, 5, fn _changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)
      |> expect(:update!, 7, fn changeset ->
        # simulate a conflict when adding the transaction
        Repo.update!(changeset)
      end)
      |> expect(:transaction, 5, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      {:error, updated_event} =
        UpdateEvent.process_update_event(event, DoubleEntryLedger.MockRepo)

      assert updated_event.status == :occ_timeout
      assert updated_event.occ_retry_count == 5

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               updated_event.errors
    end

    test "when transaction can't be created for other reasons", %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, _pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn changeset ->
        # simulate a conflict when adding the transaction
        {:error, changeset}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{} = event} =
               UpdateEvent.process_update_event(
                 event,
                 DoubleEntryLedger.MockRepo
               )

      assert event.status == :failed
    end
  end

  defp shared_event_asserts(transaction, processed_event, pending_transaction) do
    assert processed_event.status == :processed
    assert processed_event.processed_transaction_id == pending_transaction.id
    assert transaction.id == pending_transaction.id
    assert processed_event.processed_at != nil
  end
end
