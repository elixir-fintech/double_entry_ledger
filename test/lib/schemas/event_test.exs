defmodule DoubleEntryLedger.EventTest do
  @moduledoc """
  Tests for the event
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.Event.TransactionDataFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset

  alias DoubleEntryLedger.Event.TransactionEventMap
  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Stores.EventStore

  doctest Event

  describe "changeset/2 for action: :create_transaction" do
    test "not valid for empty payload" do
      assert %Changeset{
               errors: [
                 action: {"can't be blank", [validation: :required]},
                 source: {"can't be blank", [validation: :required]},
                 source_idempk: {"can't be blank", [validation: :required]},
                 instance_id: {"can't be blank", [validation: :required]},
                 event_map: {"can't be blank", [validation: :required]}
               ]
             } = Event.changeset(%Event{}, %{})
    end

    test "valid with required attributes for action create_transaction" do
      event_map = %{
        action: :create_transaction,
        source: "source",
        instance_id: Ecto.UUID.generate(),
        instance_address: "inst1",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      attrs = Map.put(event_map, :event_map, event_map)

      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
    end

    test "idempotency is not enforced at event creation" do

      %{instance: inst} = create_instance()

      attrs = %{
        instance_address: inst.address,
        action: :create_transaction,
        source: "source",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      transaction_event_map = struct(TransactionEventMap, attrs)
      assert {:ok, event} = EventStore.create(transaction_event_map)
      assert {:ok, event2} = EventStore.create(transaction_event_map)
      assert event.id != event2.id
    end
  end

  describe "changeset/2 for action: :update_transaction" do
    test "changeset valid for simple update action, without any entry information" do
      event_map = %{
        action: :update_transaction,
        source: "source",
        instance_id: Ecto.UUID.generate(),
        instance_address: "inst1",
        source_idempk: "source_idempk",
        update_idempk: "update_idempk",
        payload: %{
          status: :posted
        }
      }

      attrs = Map.put(event_map, :event_map, event_map)

      assert %Changeset{
               valid?: true
             } =
               Event.changeset(%Event{}, attrs)
    end

    test "idempotency is not enforced when creating events" do
      %{instance: inst} = create_instance()

      attrs = %TransactionEventMap{
        instance_address: inst.address,
        action: :update_transaction,
        source: "source",
        source_idempk: "source_idempk",
        update_idempk: "update_idempk",
        payload: pending_payload()
      }

      assert {:ok, event} = EventStore.create(attrs)
      assert {:ok, event2} = EventStore.create(attrs)
      assert event.id != event2.id
    end
  end
end
