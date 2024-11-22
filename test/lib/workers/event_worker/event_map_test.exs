defmodule DoubleEntryLedger.EventWorker.EventMapTest do
  @moduledoc """
  This module tests the EventMap module.
  """
  use ExUnit.Case
  import Mox

      alias DoubleEntryLedger.EventStore
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

      {:error, error} = EventMap.process_map(update_event)
      assert match?(error, "Create event (id: #{pending_event.id}) has not yet been processed for Update Even.*")
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
