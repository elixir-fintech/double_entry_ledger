defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionEventMapNoSaveOnErrorTest do
  @moduledoc """
  This module tests the UpdateTransactionEventMapNoSaveOnError module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import Mox

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.TransactionEventMap, as: TransactionEventMapSchema
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionEventMapNoSaveOnError
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEvent

  doctest UpdateTransactionEventMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "update event for event_map, which should also create the event", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateTransactionEvent.process(pending_event)

      update_event = update_transaction_event_map(ctx, pending_event, :posted)

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        UpdateTransactionEventMapNoSaveOnError.process(update_event)

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
      CreateTransactionEvent.process(pending_event)
      update_event = update_transaction_event_map(ctx, pending_event, :posted)
      UpdateTransactionEventMapNoSaveOnError.process(update_event)

      # process same update_event again which should fail
      {:error, changeset} = UpdateTransactionEventMapNoSaveOnError.process(update_event)
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

      assert {:error,
              %Changeset{
                data: %TransactionEventMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_event_not_found", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionEventMapNoSaveOnError.process(update_transaction_event_map)
    end

    test "return TransactionEventMap changeset for other errors", ctx do
      event_map = %{
        create_transaction_event_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      updated_event_map =
        update_in(
          event_map,
          [Access.key!(:payload), Access.key!(:entries), Access.at(1), Access.key!(:currency)],
          fn _ ->
            "USD"
          end
        )

      # process same update_event again which should fail
      {:error, changeset} =
        UpdateTransactionEventMapNoSaveOnError.process(updated_event_map)

      assert %Changeset{data: %TransactionEventMapSchema{}} = changeset
    end

    test "return TransactionEventMap changeset for invalid entry data currency", ctx do
      event_map = %{
        create_transaction_event_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      updated_event_map =
        update_in(
          event_map,
          [Access.key!(:payload), Access.key!(:entries), Access.at(1), Access.key!(:currency)],
          fn _ ->
            "XYZ"
          end
        )

      {:error, changeset} =
        UpdateTransactionEventMapNoSaveOnError.process(updated_event_map)

      assert %Changeset{
               data: %TransactionEventMapSchema{},
               errors: [
                 input_event_map: {"invalid_entry_data", []},
                 action: {"invalid in this context", [value: ""]}
               ]
             } = changeset
    end

    test "return TransactionEventMap changeset for non existing account", ctx do
      event_map = %{
        create_transaction_event_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      updated_event_map =
        update_in(
          event_map,
          [
            Access.key!(:payload),
            Access.key!(:entries),
            Access.at(1),
            Access.key!(:account_address)
          ],
          fn _ ->
            "non:existing:#{:rand.uniform(1000)}"
          end
        )

      {:error, changeset} =
        UpdateTransactionEventMapNoSaveOnError.process(updated_event_map)

      assert %Changeset{
               data: %TransactionEventMapSchema{},
               errors: [
                 input_event_map: {"some_accounts_not_found", []},
                 action: {"invalid in this context", [value: ""]}
               ]
             } = changeset
    end

    test "update event for event_map, when create event not yet processed", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)
      update_event = update_transaction_event_map(ctx, pending_event, :posted)

      assert {:error,
              %Changeset{
                data: %TransactionEventMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_event_not_processed", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionEventMapNoSaveOnError.process(update_event)
    end

    test "update event is pending for event_map, when create event failed", ctx do
      %{event: %{event_queue_item: eqm1} = pending_event} =
        new_create_transaction_event(ctx, :pending)

      failed_event =
        pending_event
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.put_assoc(:event_queue_item, %{id: eqm1.id, status: :failed})
        |> Repo.update!()

      update_event = update_transaction_event_map(ctx, failed_event, :posted)

      assert {:error,
              %Changeset{
                data: %TransactionEventMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_event_not_processed", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionEventMapNoSaveOnError.process(update_event)
    end

    test "update event is dead_letter for event_map, when create event failed", ctx do
      %{event: pending_event} = new_create_transaction_event(ctx, :pending)

      pending_event.event_queue_item
      |> Ecto.Changeset.change(%{status: :dead_letter})
      |> Repo.update!()

      failed_event = Repo.preload(pending_event, :event_queue_item)

      update_event = update_transaction_event_map(ctx, failed_event, :posted)

      assert {:error,
              %Changeset{
                data: %TransactionEventMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_event_in_dead_letter", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionEventMapNoSaveOnError.process(update_event)
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

      assert {:error,
              %Changeset{data: %TransactionEventMapSchema{}, errors: [occ_timeout: _, action: _]}} =
               UpdateTransactionEventMapNoSaveOnError.process(
                 update_event,
                 DoubleEntryLedger.MockRepo
               )
    end
  end
end
