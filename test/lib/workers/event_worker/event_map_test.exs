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

  alias DoubleEntryLedger.EventWorker.ProcessEventMap
  alias DoubleEntryLedger.EventWorker.CreateEvent
  alias DoubleEntryLedger.Event

  doctest ProcessEventMap

  describe "process_map/1" do
    setup [:create_instance, :create_accounts]

    test "create event for event_map, which must also create the event", ctx do
      event_map = struct(EventMapSchema, event_map(ctx))

      {:ok, transaction, processed_event} = ProcessEventMap.process_map(event_map)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :pending
    end

    test "return EventMap changeset for duplicate source_idempk", ctx do
      # successfully create event
      event_map = struct(EventMapSchema, event_map(ctx))
      ProcessEventMap.process_map(event_map)

      # process same event_map again which should fail
      {:error, changeset} = ProcessEventMap.process_map(event_map)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :source_idempk)
    end

    test "return EventMap changeset for duplicate update_idempk", ctx do
      # successfully create event
      %{event: pending_event} = create_event(ctx, :pending)
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))
      ProcessEventMap.process_map(update_event)

      # process same update_event again which should fail
      {:error, changeset} = ProcessEventMap.process_map(update_event)
      assert %Changeset{data: %EventMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :update_idempk)
    end

    test "return EventMap changeset for other errors", ctx do
      # successfully create event
      event_map = event_map(ctx, :pending)

      updated_event_map =
        update_in(event_map, [:transaction_data, :entries, Access.at(1), :currency], fn _ ->
          "USD"
        end)

      # process same update_event again which should fail
      {:error, changeset} = ProcessEventMap.process_map(struct(EventMapSchema, updated_event_map))
      assert %Changeset{data: %EventMapSchema{}} = changeset
    end

    test "update event for event_map, which should also create the event", ctx do
      %{event: pending_event} = create_event(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateEvent.process_create_event(pending_event)

      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      {:ok, transaction, processed_event} = ProcessEventMap.process_map(update_event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_transaction_id == pending_transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end

    test "update event for event_map, when create event not yet processed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      {:error, event_map} = ProcessEventMap.process_map(update_event)
      assert is_struct(event_map, Event)

      saved_update_event =
        Event
        |> where(
          [e],
          e.source == ^pending_event.source and e.source_idempk == ^pending_event.source_idempk and
            not is_nil(e.update_idempk)
        )
        |> Repo.one()

      assert saved_update_event.status == :pending
      assert saved_update_event.id != pending_event.id
    end

    test "update event for event_map, when create event failed", ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      EventStore.mark_as_failed(pending_event, "Failed to create event")
      update_event = struct(EventMapSchema, update_event_map(ctx, pending_event, :posted))

      {:error, event_map} = ProcessEventMap.process_map(update_event)

      assert is_struct(event_map, Changeset)
      {error_message, _} = Keyword.get(event_map.errors, :source_idempk)
      assert error_message =~ "Create event (id: #{pending_event.id}) has failed"

      assert is_nil(
               Event
               |> where(
                 [e],
                 e.source == ^pending_event.source and
                   e.source_idempk == ^pending_event.source_idempk and not is_nil(e.update_idempk)
               )
               |> Repo.one()
             )
    end
  end

  describe "process_map/2 with OCC timeout" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "with last retry that fails", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: changeset
      end)
      |> expect(:transaction, 5, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Event{id: id, status: :occ_timeout}} =
               ProcessEventMap.process_map(
                 struct(EventMapSchema, event_map(ctx)),
                 DoubleEntryLedger.MockRepo
               )

      assert %Event{status: :occ_timeout, occ_retry_count: 5} = updated_event = Repo.get(Event, id)
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = updated_event.errors
    end
  end
end
