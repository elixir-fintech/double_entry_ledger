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

  describe "changeset/2 for action: :create_transaction" do
    test "not valid for empty payload" do
      assert %Changeset{
               errors: [
                 transaction_data: {"can't be blank", [validation: :required]},
                 action: {"can't be blank", [validation: :required]},
                 source: {"can't be blank", [validation: :required]},
                 source_idempk: {"can't be blank", [validation: :required]},
                 instance_id: {"can't be blank", [validation: :required]}
               ]
             } = Event.changeset(%Event{}, %{})
    end

    test "valid with required attributes for action create_transaction" do
      attrs = %{
        action: :create_transaction,
        source: "source",
        instance_id: Ecto.UUID.generate(),
        source_idempk: "source_idempk",
        transaction_data: pending_payload()
      }

      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
    end

    test "idempotent: can't save the same event twice" do
      %{instance: inst} = create_instance()

      attrs = %{
        instance_id: inst.id,
        action: :create_transaction,
        source: "source",
        source_idempk: "source_idempk",
        transaction_data: pending_payload()
      }

      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
      assert {:ok, _event} = EventStore.create(attrs)

      assert {:error, %{errors: [source_idempk: {_, [{:constraint, :unique}, _]}]}} =
               EventStore.create(attrs)
    end
  end

  describe "changeset/2 for action: :update_transaction" do
    test "changeset valid for simple update action, without any entry information" do
      attrs = %{
        action: :update_transaction,
        source: "source",
        instance_id: Ecto.UUID.generate(),
        source_idempk: "source_idempk",
        update_idempk: "update_idempk",
        transaction_data: %{
          status: :posted
        }
      }

      assert %Changeset{
               valid?: true,
               changes: %{transaction_data: %{changes: %{status: :posted}}}
             } =
               Event.changeset(%Event{}, attrs)
    end

    test "idempotent: can't save the same update event twice" do
      %{instance: inst} = create_instance()

      attrs = %{
        instance_id: inst.id,
        action: :update_transaction,
        source: "source",
        source_idempk: "source_idempk",
        update_idempk: "update_idempk",
        transaction_data: pending_payload()
      }

      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
      assert {:ok, _event} = EventStore.create(attrs)

      assert {:error, %{errors: [update_idempk: {_, [{:constraint, :unique}, _]}]}} =
               EventStore.create(attrs)

      # check it's true for posted and archived status as well
      posted_payload = put_in(attrs, [:transaction_data, :status], :posted)
      archived_payload = put_in(attrs, [:transaction_data, :status], :archived)

      assert {:error, %{errors: [update_idempk: {_, [{:constraint, :unique}, _]}]}} =
               EventStore.create(posted_payload)

      assert {:error, %{errors: [update_idempk: {_, [{:constraint, :unique}, _]}]}} =
               EventStore.create(archived_payload)
    end
  end
end
