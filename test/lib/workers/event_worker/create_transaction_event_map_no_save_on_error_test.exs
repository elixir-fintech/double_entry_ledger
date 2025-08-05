defmodule DoubleEntryLedger.EventWorker.CreateTransactionEventMapNoSaveOnErrorTest do
  @moduledoc """
  This module tests the CreateTransactionEventMapNoSaveOnError module, which processes event maps for transaction creation without saving on error. It ensures that errors return changesets and no partial data is persisted.
  """
  use ExUnit.Case
  import Mox

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.EventMap, as: EventMapSchema
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.EventWorker.CreateTransactionEventMapNoSaveOnError

  doctest CreateTransactionEventMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", ctx do
      event_map = struct(EventMapSchema, event_map(ctx))

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        CreateTransactionEventMapNoSaveOnError.process(event_map)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :pending
    end

    test "return EventMap changeset for duplicate source_idempk", ctx do
      # successfully create event
      event_map = struct(EventMapSchema, event_map(ctx))
      CreateTransactionEventMapNoSaveOnError.process(event_map)

      # process same event_map again which should fail
      {:error, changeset} = CreateTransactionEventMapNoSaveOnError.process(event_map)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :source_idempk)
    end

    test "return EventMap changeset for other errors", ctx do
      # successfully create event
      event_map = event_map(ctx, :pending)

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :currency], fn _ ->
          "USD"
        end)

      # process same update_event again which should fail
      {:error, changeset} =
        CreateTransactionEventMapNoSaveOnError.process(struct(EventMapSchema, updated_event_map))

      assert %Changeset{data: %EventMapSchema{}} = changeset
    end

    test "return EventMap changeset for invalid entry data currency", ctx do
      event_map = event_map(ctx, :pending)

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :currency], fn _ ->
          "XYZ"
        end)

      {:error, changeset} =
        CreateTransactionEventMapNoSaveOnError.process(struct(EventMapSchema, updated_event_map))

      assert %Changeset{
               data: %EventMapSchema{},
               errors: [input_event_map: {"invalid_entry_data", []}]
             } = changeset
    end

    test "return EventMap changeset for non existing account", ctx do
      event_map = event_map(ctx, :pending)

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :account_id], fn _ ->
          Ecto.UUID.generate()
        end)

      {:error, changeset} =
        CreateTransactionEventMapNoSaveOnError.process(struct(EventMapSchema, updated_event_map))

      assert %Changeset{
               data: %EventMapSchema{},
               errors: [input_event_map: {"some_accounts_not_found", []}]
             } = changeset
    end
  end

  describe "process_map/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Changeset{data: %EventMapSchema{}, errors: [occ_timeout: _]}} =
               CreateTransactionEventMapNoSaveOnError.process(
                 struct(
                   EventMapSchema,
                   event_map(ctx)
                 ),
                 DoubleEntryLedger.MockRepo
               )
    end
  end
end
