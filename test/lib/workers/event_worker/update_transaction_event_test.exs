defmodule DoubleEntryLedger.UpdateTransactionEventTest do
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
  alias DoubleEntryLedger.Workers.EventWorker.{UpdateTransactionEvent, CreateTransactionEvent}
  alias DoubleEntryLedger.EventQueue.Scheduling

  doctest UpdateTransactionEvent

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "process update event successfully for simple update to posted",
         %{instance: inst} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]
      {:ok, event} = new_update_transaction_event(s, s_id, inst.address, :posted)

      {:ok, transaction, processed_event} = UpdateTransactionEvent.process(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [100, 100]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "process update event successfully for simple update to :archived",
         %{instance: inst} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]
      {:ok, event} = new_update_transaction_event(s, s_id, inst.address, :archived)

      {:ok, transaction, processed_event} = UpdateTransactionEvent.process(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "process update event successfully for changing entries and to :posted",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        new_update_transaction_event(s, s_id, inst.address, :posted, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateTransactionEvent.process(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_available_balances(ctx) == [50, 50]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "process update event successfully for changing entries and to :pending",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        new_update_transaction_event(s, s_id, inst.address, :pending, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateTransactionEvent.process(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [50, 50]
      assert transaction.status == :pending
    end

    test "process update event successfully to :archived",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, event} =
        new_update_transaction_event(s, s_id, inst.address, :archived, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_event} = UpdateTransactionEvent.process(event)
      shared_event_asserts(transaction, processed_event, pending_transaction)
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "dead letter when create event does not exist", %{instance: inst} do
      {:ok, event} = new_update_transaction_event("source", "1", inst.address, :posted)

      {:error, %{event_queue_item: evq}} = UpdateTransactionEvent.process(event)
      assert evq.status == :dead_letter

      [error | _] = evq.errors

      assert error.message ==
               "create Event not found for Update Event (id: #{event.id})"
    end

    test "back to pending when create event is still pending", %{instance: inst} = ctx do
      %{event: %{id: e_id, source: s, source_idempk: s_id}} =
        new_create_transaction_event(ctx, :pending)

      {:ok, event} = new_update_transaction_event(s, s_id, inst.address, :posted)

      {:ok, processing_event} = Scheduling.claim_event_for_processing(event.id, "manual")

      {:error, %{event_queue_item: eqm}} = UpdateTransactionEvent.process(processing_event)
      assert eqm.status == :pending

      [error | _] = eqm.errors

      assert error.message ==
               "create Event (id: #{e_id}, status: pending) not yet processed for Update Event (id: #{event.id})"
    end

    test "back to pending when create event failed", %{instance: inst} = ctx do
      %{event: %{source: s, source_idempk: s_id} = pending_event} =
        new_create_transaction_event(ctx, :pending)

      {:error, failed_create_event} =
        DoubleEntryLedger.EventQueue.Scheduling.schedule_retry_with_reason(
          pending_event,
          "some reason",
          :failed
        )

      {:ok, event} = new_update_transaction_event(s, s_id, inst.address, :posted)

      {:error, %{event_queue_item: eqm}} = UpdateTransactionEvent.process(event)
      assert eqm.status == :pending

      [error | _] = eqm.errors

      assert failed_create_event.event_queue_item.status == :failed

      assert error.message ==
               "create Event (id: #{pending_event.id}, status: failed) not yet processed for Update Event (id: #{event.id})"
    end

    test "dead_letter when create event in dead_letter", %{instance: inst} = ctx do
      %{event: %{source: s, source_idempk: s_id} = pending_event} =
        new_create_transaction_event(ctx, :pending)

      DoubleEntryLedger.EventQueue.Scheduling.build_mark_as_dead_letter(
        pending_event,
        "some reason"
      )
      |> DoubleEntryLedger.Repo.update!()

      {:ok, event} = new_update_transaction_event(s, s_id, inst.address, :posted)

      {:error, %{event_queue_item: eqm}} = UpdateTransactionEvent.process(event)
      assert eqm.status == :dead_letter

      [error | _] = eqm.errors

      assert error.message ==
               "create Event (id: #{pending_event.id}) in dead_letter for Update Event (id: #{event.id})"
    end

    test "update event with last retry that fails", %{instance: inst} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, _pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      {:ok, event} = new_update_transaction_event(s, s_id, inst.address, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, 5, fn _changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
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
        UpdateTransactionEvent.process(event, DoubleEntryLedger.MockRepo)

      assert eqm.status == :occ_timeout
      assert eqm.occ_retry_count == 5
      %{transactions: []} = Repo.preload(updated_event, :transactions)
      assert eqm.processing_completed_at != nil
      assert length(eqm.errors) == 5
      assert eqm.retry_count == 0
      assert eqm.next_retry_after != nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               eqm.errors
    end

    test "when transaction can't be created for other reasons", %{instance: inst} = ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, _pending_transaction, %{source: s, source_idempk: s_id}} =
        CreateTransactionEvent.process(pending_event)

      {:ok, event} =
        new_update_transaction_event(s, s_id, inst.address, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        # simulate a conflict when adding the transaction
        {:error, :conflict}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{event_queue_item: eqm}} =
               UpdateTransactionEvent.process(
                 event,
                 DoubleEntryLedger.MockRepo
               )

      assert eqm.status == :failed

      assert [
               %{message: "UpdateTransactionEvent: Step :transaction failed. Error: :conflict"}
               | _
             ] =
               eqm.errors
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
