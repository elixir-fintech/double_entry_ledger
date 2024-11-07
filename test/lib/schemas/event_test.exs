defmodule DoubleEntryLedger.EventTest do
  @moduledoc """
  Tests for the event
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.Event.TransactionDataFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset

  alias DoubleEntryLedger.{Event, EventStore}

  doctest Event

  describe "changeset" do
    setup [:create_instance]

    test "changeset not valid for empty payload" do
      assert %Changeset{errors: [
        transaction_data: {"can't be blank", [validation: :required]},
        action: {"can't be blank", [validation: :required]},
        source: {"can't be blank", [validation: :required]},
        source_idempk: {"can't be blank", [validation: :required]},
        instance_id: {"can't be blank", [validation: :required]}
      ]} = Event.changeset(%Event{}, %{})
    end

    test "changeset valid with required attributes for action create" do
      attrs = %{
        action: :create,
        source: "source",
        instance_id: Ecto.UUID.generate(),
        source_idempk: "source_idempk",
        transaction_data: pending_payload()
      }
      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
    end

    test "can't save the same event twice", %{instance: inst} do
      attrs = %{
        instance_id: inst.id,
        action: :create,
        source: "source",
        source_idempk: "source_idempk",
        transaction_data: pending_payload()
      }
      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
      assert {:ok, _event} = EventStore.insert_event(attrs)
      assert {:error, %{errors: [
        source_idempk: {_, [{:constraint, :unique}, _]}
      ]
      }} = EventStore.insert_event(attrs)
    end

    test "changeset valid for simple update action, without any entry information" do
      attrs = %{
        action: :update,
        source: "source",
        instance_id: Ecto.UUID.generate(),
        source_idempk: "source_idempk",
        transaction_data: %{
          status: :posted,
        }
      }
      assert %Changeset{
        valid?: true,
        changes: %{transaction_data: %{changes: %{status: :posted}}}} = Event.changeset(%Event{}, attrs)
    end
  end
end
