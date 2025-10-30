defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionEventMapTest do
  @moduledoc """
  This module tests the TransactionEventMap module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import Mox

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.TransactionEventMap, as: TransactionEventMapSchema
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionEventMap
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEvent
  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Stores.CommandStore

  doctest UpdateTransactionEventMap

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "update event for event_map, which should also create the event", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateTransactionEvent.process(pending_event)

      update_event = update_transaction_event_map(ctx, pending_event, :posted)

      {:ok, transaction, %{command_queue_item: evq} = processed_event} =
        UpdateTransactionEventMap.process(update_event)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert processed_transaction.id == pending_transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "return TransactionEventMap changeset for duplicate update_idempk", ctx do
      # successfully create event
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)
      update_event = update_transaction_event_map(ctx, pending_event, :posted)
      UpdateTransactionEventMap.process(update_event)

      # process same update_event again which should fail
      {:error, changeset} = UpdateTransactionEventMap.process(update_event)
      assert %Changeset{data: %TransactionEventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :key_hash)
    end

    test "dead letter when create event does not exist", ctx do
      event_map = create_transaction_event_map(ctx, :pending)

      update_transaction_event_map = %{
        event_map
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      {:error, %{command_queue_item: %{status: status, errors: [error | _]}}} =
        UpdateTransactionEventMap.process(update_transaction_event_map)

      assert status == :dead_letter
      assert error.message =~ "create Command not found for Update Command (id:"
    end

    test "update event for event_map, when create event not yet processed", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)
      update_event = update_transaction_event_map(ctx, pending_event, :posted)

      {:error, %{command_queue_item: eqm} = update_event} =
        UpdateTransactionEventMap.process(update_event)

      assert eqm.status == :pending
      assert update_event.id != pending_event.id
      %{transactions: []} = Repo.preload(update_event, :transactions)
      assert eqm.processing_completed_at == nil
      assert eqm.errors != []
    end

    test "update event is pending for event_map, when create event failed", ctx do
      %{event: %{command_queue_item: eqm1} = pending_event} =
        new_create_transaction_event(ctx, :pending)

      failed_event =
        pending_event
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.put_assoc(:command_queue_item, %{id: eqm1.id, status: :failed})
        |> Repo.update!()

      update_event = update_transaction_event_map(ctx, failed_event, :posted)

      {:error, %{command_queue_item: eqm}} = UpdateTransactionEventMap.process(update_event)

      assert eqm.status == :pending
    end

    test "update event is dead_letter for event_map, when create event failed", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      pending_event.command_queue_item
      |> Ecto.Changeset.change(%{status: :dead_letter})
      |> Repo.update!()

      failed_event = Repo.preload(pending_event, :command_queue_item)

      update_event = update_transaction_event_map(ctx, failed_event, :posted)

      {:error, %{command_queue_item: evq}} = UpdateTransactionEventMap.process(update_event)

      assert evq.status == :dead_letter
    end
  end

  TODO

  describe "process/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)
      CreateTransactionEvent.process(pending_event)
      update_event = update_transaction_event_map(ctx, pending_event, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Command{id: id, command_queue_item: %{status: :occ_timeout}}} =
               UpdateTransactionEventMap.process(update_event, DoubleEntryLedger.MockRepo)

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5, errors: errors},
               transactions: []
             } =
               CommandStore.get_by_id(id) |> Repo.preload(:transactions)

      assert length(errors) == 5
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = errors
    end
  end
end
