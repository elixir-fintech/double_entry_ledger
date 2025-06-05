defmodule DoubleEntryLedger.EventWorker.EventMapTest do
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
  alias DoubleEntryLedger.EventWorker.UpdateEventMap
  alias DoubleEntryLedger.EventWorker.CreateEvent
  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.EventStore

  doctest UpdateEventMap

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "update event for event_map, which should also create the event", ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateEvent.process_create_event(pending_event)

      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      {:ok, transaction, %{event_queue_item: evq} = processed_event} =
        UpdateEventMap.process(update_event)

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
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))
      UpdateEventMap.process(update_event)

      # process same update_event again which should fail
      {:error, changeset} = UpdateEventMap.process(update_event)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :update_idempk)
    end

    test "dead letter when create event does not exist", ctx do
      event_map = event_map(ctx, :pending)
      update_event_map = %{event_map | update_idempk: Ecto.UUID.generate(), action: :update}

      {:error, %{event_queue_item: %{status: status, errors: [error | _]}}} =
        UpdateEventMap.process(update_event_map)

      assert status == :dead_letter
      assert error.message =~ "Create Event not found for Update Event (id:"
    end

    test "update event for event_map, when create event not yet processed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      {:error, %{event_queue_item: eqm} = update_event} =
        UpdateEventMap.process(update_event)

      assert eqm.status == :pending
      assert update_event.id != pending_event.id
      %{transactions: []} = Repo.preload(update_event, :transactions)
      assert eqm.processing_completed_at == nil
      assert eqm.errors != []
    end

    test "update event is pending for event_map, when create event failed", ctx do
      %{event: %{event_queue_item: eqm1} = pending_event} = create_event(ctx, :pending)

      failed_event =
        pending_event
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.put_assoc(:event_queue_item, %{id: eqm1.id, status: :failed})
        |> Repo.update!()

      update_event = struct(EventMapSchema, update_event_map(ctx, failed_event, :posted))

      {:error, %{event_queue_item: eqm}} = UpdateEventMap.process(update_event)

      assert eqm.status == :pending
    end

    test "update event is dead_letter for event_map, when create event failed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      pending_event.event_queue_item
      |> Ecto.Changeset.change(%{status: :dead_letter})
      |> Repo.update!()

      failed_event = Repo.preload(pending_event, :event_queue_item)

      update_event = struct(EventMapSchema, update_event_map(ctx, failed_event, :posted))

      {:error, %{event_queue_item: evq}} = UpdateEventMap.process(update_event)

      assert evq.status == :dead_letter
    end
  end

  TODO

  describe "process/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      CreateEvent.process_create_event(pending_event)
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

      assert {:error, %Event{id: id, event_queue_item: %{status: :occ_timeout}}} =
               UpdateEventMap.process(update_event, DoubleEntryLedger.MockRepo)

      assert %Event{
               event_queue_item: %{status: :occ_timeout, occ_retry_count: 5, errors: errors},
               transactions: []
             } =
               EventStore.get_by_id(id) |> Repo.preload(:transactions)

      assert length(errors) == 5
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = errors
    end
  end
end
