defmodule DoubleEntryLedger.EventWorker.EventMapTest do
  @moduledoc """
  This module tests the EventMap module.
  """
  use ExUnit.Case
  import Mox

  alias Ecto.Changeset
  alias DoubleEntryLedger.EventStore
  alias DoubleEntryLedger.Event.EventMap, as: EventMapSchema
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  import DoubleEntryLedger.EventWorker.EventTransformer,
    only: [transaction_data_to_transaction_map: 2]

  alias DoubleEntryLedger.EventWorker.EventMap
  alias DoubleEntryLedger.EventWorker.CreateEvent
  alias DoubleEntryLedger.Event

  doctest EventMap

  describe "process_map/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", ctx do
      event_map = event_map(ctx)

      {:ok, transaction, processed_event} = EventMap.process_map(event_map)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :pending
    end

    test "return EventMap changeset for duplicate source_idempk", ctx do
      #successfully create event
      event_map = event_map(ctx)
      EventMap.process_map(event_map)

      # process same event_map again which should fail
      {:error, changeset} = EventMap.process_map(event_map)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :source_idempk)
    end

    test "return EventMap changeset for duplicate update_idempk", ctx do
      #successfully create event
      %{event: pending_event} = create_event(ctx, :pending)
      update_event = update_event_map(ctx, pending_event, :posted)
      EventMap.process_map(update_event)

      # process same update_event again which should fail
      {:error, changeset} = EventMap.process_map(update_event)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :update_idempk)
    end

    test "update event for event_map, which should also create the event", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, {pending_transaction, _}} =
        CreateEvent.process_create_event(pending_event)
      update_event = update_event_map(ctx, pending_event, :posted)

      {:ok, transaction, processed_event } = EventMap.process_map(update_event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_transaction_id == pending_transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end

    test "update event for event_map, when create event not yet processed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      update_event = update_event_map(ctx, pending_event, :posted)

      {:error, error_message} = EventMap.process_map(update_event)
      assert error_message =~ "Create event (id: #{pending_event.id}) has not yet been processed for Update Even"
      saved_update_event = Event
      |> where([e], e.source == ^pending_event.source and e.source_idempk == ^pending_event.source_idempk and not is_nil(e.update_idempk))
      |> Repo.one()

      assert saved_update_event.status == :pending
      assert saved_update_event.id != pending_event.id
    end

    test "update event for event_map, when create event failed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      EventStore.mark_as_failed(pending_event, "Failed to create event")
      update_event = update_event_map(ctx, pending_event, :posted)

      {:error, error_message} = EventMap.process_map(update_event)
      assert error_message =~ "Create event (id: #{pending_event.id}) has failed for Update Event"
      saved_update_event = Event
      |> where([e], e.source == ^pending_event.source and e.source_idempk == ^pending_event.source_idempk and not is_nil(e.update_idempk))
      |> Repo.one()

      assert saved_update_event.status == :failed
      assert saved_update_event.id != pending_event.id
    end
  end

  describe "process_map_with_retry/2" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "with last retry that fails", ctx do
      %{transaction_data: td, instance_id: id} = event_map = event_map(ctx)
      {:ok, transaction_map} = transaction_data_to_transaction_map(td, id)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: changeset
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, :transaction, :occ_final_timeout, %Event{id: id}} =
               EventMap.process_map_with_retry(
                 event_map,
                 transaction_map,
                 %{errors: [], steps_so_far: %{}, retries: 1},
                 1,
                 DoubleEntryLedger.MockRepo
               )

      assert %Event{status: :occ_timeout, tries: 2} = Repo.get(Event, id)
    end
  end
end
