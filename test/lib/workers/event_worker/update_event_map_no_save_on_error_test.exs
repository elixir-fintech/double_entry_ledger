defmodule DoubleEntryLedger.EventWorker.UpdateEventMapNoSaveOnErrorTest do
  @moduledoc """
  This module tests the EventMap module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import Mox

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.EventMap, as: EventMapSchema
  alias DoubleEntryLedger.EventWorker.UpdateEventMapNoSaveOnError
  alias DoubleEntryLedger.EventWorker.CreateEvent

  doctest UpdateEventMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "update event for event_map, which should also create the event", ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateEvent.process(pending_event)

      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        UpdateEventMapNoSaveOnError.process(update_event)

      assert evq.status == :processed

      %{transactions: [processed_transaction | []]} = Repo.preload(processed_event, :transactions)

      assert processed_transaction.id == transaction.id
      assert processed_transaction.id == pending_transaction.id
      assert evq.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "return EventMap changeset for duplicate update_idempk", ctx do
      # successfully create event
      %{event: pending_event} = create_event(ctx, :pending)
      CreateEvent.process(pending_event)
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))
      UpdateEventMapNoSaveOnError.process(update_event)

      # process same update_event again which should fail
      {:error, changeset} = UpdateEventMapNoSaveOnError.process(update_event)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :update_idempk)
    end

    test "dead letter when create event does not exist", ctx do
      event_map = event_map(ctx, :pending)
      update_event_map = %{event_map | update_idempk: Ecto.UUID.generate(), action: :update}

      assert {:error,
              %Changeset{
                data: %EventMapSchema{},
                errors: [create_event_error: {"create_event_not_found", _}]
              }} =
               UpdateEventMapNoSaveOnError.process(update_event_map)
    end

    test "return EventMap changeset for other errors", ctx do
      event_map = %{
        event_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update
      }

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :currency], fn _ ->
          "USD"
        end)

      # process same update_event again which should fail
      {:error, changeset} =
        UpdateEventMapNoSaveOnError.process(struct(EventMapSchema, updated_event_map))

      assert %Changeset{data: %EventMapSchema{}} = changeset
    end

    test "return EventMap changeset for invalid entry data currency", ctx do
      event_map = %{
        event_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update
      }

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :currency], fn _ ->
          "XYZ"
        end)

      {:error, changeset} =
        UpdateEventMapNoSaveOnError.process(struct(EventMapSchema, updated_event_map))

      assert %Changeset{
               data: %EventMapSchema{},
               errors: [input_event_map: {"invalid_entry_data", []}]
             } = changeset
    end

    test "return EventMap changeset for non existing account", ctx do
      event_map = %{
        event_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update
      }

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :account_id], fn _ ->
          Ecto.UUID.generate()
        end)

      {:error, changeset} =
        UpdateEventMapNoSaveOnError.process(struct(EventMapSchema, updated_event_map))

      assert %Changeset{
               data: %EventMapSchema{},
               errors: [input_event_map: {"some_accounts_not_found", []}]
             } = changeset
    end

    test "update event for event_map, when create event not yet processed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      assert {:error,
              %Changeset{
                data: %EventMapSchema{},
                errors: [create_event_error: {"create_event_not_processed", _}]
              }} =
               UpdateEventMapNoSaveOnError.process(update_event)
    end

    test "update event is pending for event_map, when create event failed", ctx do
      %{event: %{event_queue_item: eqm1} = pending_event} = create_event(ctx, :pending)

      failed_event =
        pending_event
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.put_assoc(:event_queue_item, %{id: eqm1.id, status: :failed})
        |> Repo.update!()

      update_event = struct(EventMapSchema, update_event_map(ctx, failed_event, :posted))

      assert {:error,
              %Changeset{
                data: %EventMapSchema{},
                errors: [create_event_error: {"create_event_not_processed", _}]
              }} =
               UpdateEventMapNoSaveOnError.process(update_event)
    end

    test "update event is dead_letter for event_map, when create event failed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      pending_event.event_queue_item
      |> Ecto.Changeset.change(%{status: :dead_letter})
      |> Repo.update!()

      failed_event = Repo.preload(pending_event, :event_queue_item)

      update_event = struct(EventMapSchema, update_event_map(ctx, failed_event, :posted))

      assert {:error,
              %Changeset{
                data: %EventMapSchema{},
                errors: [create_event_error: {"create_event_in_dead_letter", _}]
              }} =
               UpdateEventMapNoSaveOnError.process(update_event)
    end
  end

  TODO

  describe "process/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      CreateEvent.process(pending_event)
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      DoubleEntryLedger.MockRepo
      |> expect(:update, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Changeset{data: %EventMapSchema{}, errors: [occ_timeout: _]}} =
               UpdateEventMapNoSaveOnError.process(update_event, DoubleEntryLedger.MockRepo)
    end
  end
end
