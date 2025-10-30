defmodule DoubleEntryLedger.EventTest do
  @moduledoc """
  Tests for the event
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.Command.TransactionDataFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset

  alias DoubleEntryLedger.Command.TransactionEventMap
  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Stores.CommandStore

  doctest Command

  describe "changeset/2 for action: :create_transaction" do
    test "not valid for empty payload" do
      assert %Changeset{
               errors: [
                 instance_id: {"can't be blank", [validation: :required]},
                 event_map: {"can't be blank", [validation: :required]}
               ]
             } = Command.changeset(%Command{}, %{})
    end

    test "valid with required attributes for action create_transaction" do
      event_map = %{
        action: :create_transaction,
        source: "source",
        instance_address: "inst1",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      attrs = %{instance_id: Ecto.UUID.generate(), event_map: event_map}

      assert %Changeset{valid?: true} = Command.changeset(%Command{}, attrs)
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

      changeset = Command.changeset(%Command{}, %{instance_id: inst.id, event_map: attrs})
      assert {:ok, event} = Repo.insert(changeset)
      assert {:ok, event2} = Repo.insert(changeset)
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
               Command.changeset(%Command{}, attrs)
    end

    test "idempotency is not enforced when creating events" do
      %{instance: inst} = create_instance()

      attrs = %{
        instance_address: inst.address,
        action: :update_transaction,
        source: "source",
        source_idempk: "source_idempk",
        update_idempk: "update_idempk",
        payload: pending_payload()
      }

      changeset = Command.changeset(%Command{}, %{instance_id: inst.id, event_map: attrs})
      assert {:ok, event} = Repo.insert(changeset)
      assert {:ok, event2} = Repo.insert(changeset)
      assert event.id != event2.id
    end
  end
end
