defmodule DoubleEntryLedger.UpdateEventTest do
  @moduledoc """
  This module tests the CreateEvent module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{UpdateEvent, CreateEvent, EventStore}

  doctest CreateEvent

  describe "process_update_event/1" do
    setup [:create_instance, :create_accounts]

    test "process update event successfully for simple status update", %{instance: inst} = ctx do
      %{event: pending_event} = create_event(ctx, :pending)
      {:ok, pending_transaction, processed_pending_event} = CreateEvent.process_create_event(pending_event)

      {:ok, event} = event_attrs(%{
        action: :update,
        instance_id: inst.id,
        source: processed_pending_event.source,
        source_id: processed_pending_event.source_id,
        transaction_data: %{
          status: :posted,
        }
      }) |> EventStore.insert_event()

      {:ok, transaction, processed_event } = UpdateEvent.process_update_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == pending_transaction.id
      assert transaction.id == pending_transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end
  end
end
