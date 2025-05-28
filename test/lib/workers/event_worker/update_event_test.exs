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

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.EventWorker.{UpdateEvent, CreateEvent}
  alias DoubleEntryLedger.EventQueue.Scheduling

  doctest UpdateEvent

  describe "process_update_event/1" do
    setup [:create_instance, :create_accounts]

    test "process update event successfully for simple update to posted",
         %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [100, 100]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "process update event successfully for simple update to :archived",
         %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]
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
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :posted, [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [50, 50]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "process update event successfully for changing entries and to :pending",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :pending, [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateEvent.process_update_event(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [50, 50]
      assert transaction.status == :pending
    end

    test "process update event successfully to :archived",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

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

    test "dead letter when create event does not exist", %{instance: inst} do
      {:ok, event} = create_update_event("source", "1", inst.id, :posted)

      {:error, %{event_queue_item: evq}} = UpdateEvent.process_update_event(event)
      assert evq.status == :dead_letter

      [error | _] = evq.errors

      assert error.message ==
               "Create Event not found for Update Event (id: #{event.id})"
    end

    test "back to pending when create event is still pending", %{instance: inst} = ctx do
      %{event: %{id: e_id, source: s, source_idempk: s_id}} = create_event(ctx, :pending)
      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:ok, processing_event} = Scheduling.claim_event_for_processing(event.id, "manual")

      {:error, %{event_queue_item: eqm}} = UpdateEvent.process_update_event(processing_event)
      assert eqm.status == :pending

      [error | _] = eqm.errors

      assert error.message ==
               "Create event (id: #{e_id}, status: pending) not yet processed for Update Event (id: #{event.id})"
    end

    test "back to pending when create event failed", %{instance: inst} = ctx do
      %{event: %{source: s, source_idempk: s_id} = pending_event} = create_event(ctx, :pending)

      {:error, failed_create_event} =
        DoubleEntryLedger.EventQueue.Scheduling.schedule_retry_with_reason(
          pending_event,
          "some reason",
          :failed
        )

      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:error, %{event_queue_item: eqm}} = UpdateEvent.process_update_event(event)
      assert eqm.status == :pending

      [error | _] = eqm.errors

      assert failed_create_event.event_queue_item.status == :failed

      assert error.message ==
               "Create event (id: #{pending_event.id}, status: failed) not yet processed for Update Event (id: #{event.id})"
    end

    test "dead_letter when create event in dead_letter", %{instance: inst} = ctx do
      %{event: %{source: s, source_idempk: s_id} = pending_event} = create_event(ctx, :pending)

      DoubleEntryLedger.EventQueue.Scheduling.build_mark_as_dead_letter(
        pending_event,
        "some reason"
      )
      |> DoubleEntryLedger.Repo.update!()

      {:ok, event} = create_update_event(s, s_id, inst.id, :posted)

      {:error, failed_event} = UpdateEvent.process_update_event(event)
      assert failed_event.status == :dead_letter

      [error | _] = failed_event.errors

      assert error.message ==
               "Create event (id: #{pending_event.id}) in dead_letter for Update Event (id: #{event.id})"
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
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      {:error, %{event_queue_item: eqm} = updated_event} =
        UpdateEvent.process_update_event(event, DoubleEntryLedger.MockRepo)

      assert eqm.status == :occ_timeout
      assert eqm.occ_retry_count == 5
      %{transactions: []} = Repo.preload(updated_event, :transactions)
      assert eqm.processing_completed_at != nil
      assert length(eqm.errors) == 5
      assert eqm.retry_count == 1
      assert eqm.next_retry_after != nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
              eqm.errors
    end

    test "when transaction can't be created for other reasons", %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, _pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateEvent.process_create_event(pending_event)

      {:ok, event} =
        create_update_event(s, s_id, inst.id, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        # simulate a conflict when adding the transaction
        {:error, :conflict}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{} = error_event} =
               UpdateEvent.process_update_event(
                 event,
                 DoubleEntryLedger.MockRepo
               )

      assert error_event.status == :failed

      assert [%{message: "UpdateEvent: Step :transaction failed. Error: :conflict"} | _] =
               error_event.errors
    end
  end

  defp shared_event_asserts(transaction, processed_event, pending_transaction) do
    assert processed_event.event_queue_item.status == :processed

    %{transactions: [processed_transaction | []]} =
      processed_event = Repo.preload(processed_event, :transactions)

    assert processed_transaction.id == pending_transaction.id
    assert transaction.id == pending_transaction.id
    assert processed_event.event_queue_item.processing_completed_at != nil
  end
end
