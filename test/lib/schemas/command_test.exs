defmodule DoubleEntryLedger.EventTest do
  @moduledoc """
  Tests for the command
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.Command.TransactionDataFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset

  alias DoubleEntryLedger.Command

  doctest Command

  describe "changeset/2 for action: :create_transaction" do
    test "not valid for empty payload" do
      assert %Changeset{
               errors: [
                 instance_id: {"can't be blank", [validation: :required]},
                 command_map: {"can't be blank", [validation: :required]}
               ]
             } = Command.changeset(%Command{}, %{})
    end

    test "valid with required attributes for action create_transaction" do
      command_map = %{
        action: :create_transaction,
        source: "source",
        instance_address: "inst1",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      attrs = %{instance_id: Ecto.UUID.generate(), command_map: command_map}

      assert %Changeset{valid?: true} = Command.changeset(%Command{}, attrs)
    end

    test "idempotency is not enforced at command creation" do
      %{instance: inst} = create_instance()

      attrs = %{
        instance_address: inst.address,
        action: :create_transaction,
        source: "source",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      changeset = Command.changeset(%Command{}, %{instance_id: inst.id, command_map: attrs})
      assert {:ok, command} = Repo.insert(changeset)
      assert {:ok, command2} = Repo.insert(changeset)
      assert command.id != command2.id
    end
  end

  describe "trace_context" do
    test "changeset accepts optional trace_context map" do
      command_map = %{
        action: :create_transaction,
        source: "source",
        instance_address: "inst1",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      attrs = %{
        instance_id: Ecto.UUID.generate(),
        command_map: command_map,
        trace_context: %{"traceparent" => "00-abc123"}
      }

      changeset = Command.changeset(%Command{}, attrs)
      assert changeset.valid?
      assert Changeset.get_field(changeset, :trace_context) == %{"traceparent" => "00-abc123"}
    end

    test "changeset valid without trace_context" do
      command_map = %{
        action: :create_transaction,
        source: "source",
        instance_address: "inst1",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      attrs = %{instance_id: Ecto.UUID.generate(), command_map: command_map}
      changeset = Command.changeset(%Command{}, attrs)
      assert changeset.valid?
      assert Changeset.get_field(changeset, :trace_context) == nil
    end

    test "trace_context persists to database" do
      %{instance: inst} = create_instance()

      attrs = %{
        instance_address: inst.address,
        action: :create_transaction,
        source: "source",
        source_idempk: "source_idempk",
        payload: pending_payload()
      }

      changeset =
        Command.changeset(%Command{}, %{
          instance_id: inst.id,
          command_map: attrs,
          trace_context: %{"traceparent" => "00-abc123"}
        })

      assert {:ok, command} = Repo.insert(changeset)
      reloaded = Repo.get!(Command, command.id)
      assert reloaded.trace_context == %{"traceparent" => "00-abc123"}
    end
  end

  describe "changeset/2 for action: :update_transaction" do
    test "changeset valid for simple update action, without any entry information" do
      command_map = %{
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

      attrs = Map.put(command_map, :command_map, command_map)

      assert %Changeset{
               valid?: true
             } =
               Command.changeset(%Command{}, attrs)
    end

    test "idempotency is not enforced when creating commands" do
      %{instance: inst} = create_instance()

      attrs = %{
        instance_address: inst.address,
        action: :update_transaction,
        source: "source",
        source_idempk: "source_idempk",
        update_idempk: "update_idempk",
        payload: pending_payload()
      }

      changeset = Command.changeset(%Command{}, %{instance_id: inst.id, command_map: attrs})
      assert {:ok, command} = Repo.insert(changeset)
      assert {:ok, command2} = Repo.insert(changeset)
      assert command.id != command2.id
    end
  end
end
