defmodule DoubleEntryLedger.Event.IdempotencyKeyTest do
  @moduledoc"""
    Test idempotency key
  """
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Event.IdempotencyKey
  alias DoubleEntryLedger.Repo

  describe "changeset" do
    setup [:create_instance]

    test "successfully adds idempotency key", %{instance: %{id: id}} do
      assert {:ok, %IdempotencyKey{} = _} = Repo.insert(
        IdempotencyKey.changeset(id, %{source: "123", action: "create_transaction", source_idempk: "123456"})
      )
    end

    test "fails when inserting the same key", %{instance: %{id: id}} do
      assert {:ok, _} = Repo.insert(
        IdempotencyKey.changeset(id, %{source: "123", action: "create_transaction", source_idempk: "123456"})
      )

      assert {:error, %Ecto.Changeset{errors:
      [key_hash: {
        "already_exists",
        [constraint: :unique, constraint_name: "idempotency_keys_instance_id_key_hash_index"]
      }]}} = Repo.insert(
        IdempotencyKey.changeset(id, %{source: "123", action: "create_transaction", source_idempk: "123456"})
      )
    end

    test "includes the update_idempk if it exists", %{instance: %{id: id}} do
      assert {:ok, _} = Repo.insert(
        IdempotencyKey.changeset(id, %{source: "123", action: "create_transaction", source_idempk: "123456"})
      )

      assert {:ok, _} = Repo.insert(
        IdempotencyKey.changeset(id, %{source: "123", action: "create_transaction", source_idempk: "123456", update_idempk: "12345"})
      )
    end
  end
end
