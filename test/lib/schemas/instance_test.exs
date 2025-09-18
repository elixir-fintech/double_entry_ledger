defmodule DoubleEntryLedger.InstanceTest do
  @moduledoc """
  This module contains tests for the instance
  """
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Instance, Repo}

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.TransactionFixtures

  doctest Instance

  describe "changeset/2" do
    test "Name is only required field" do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 address: {"can't be blank", [validation: :required]}
               ]
             } = Instance.changeset(%Instance{}, %{})
    end

    test "sets the config and metadata to empty maps at insert" do
      {:ok, instance} =
        Repo.insert(
          Instance.changeset(%Instance{}, %{address: "some name"}),
          returning: true
        )

      assert %Instance{
               config: %{}
             } = instance
    end
  end

  describe "delete_changeset/1" do
    setup [:create_instance]

    test "it works for an instance with no accounts or transactions", %{instance: inst} do
      assert %Ecto.Changeset{
               valid?: true,
               changes: %{}
             } = Instance.delete_changeset(inst)
    end

    test "it can't be deleted for instance with accounts", %{instance: inst} do
      account_fixture(instance_id: inst.id)
      assert {:error, changeset} = Repo.delete(Instance.delete_changeset(inst))

      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 accounts:
                   {"are still associated with this entry",
                    [constraint: :no_assoc, constraint_name: _]}
               ]
             } = changeset
    end
  end

  describe "validate_account_balances" do
    setup [:create_instance, :create_accounts]

    test "it works for empty accounts", %{instance: inst} do
      assert {
               :ok,
               %{pending_credit: 0, pending_debit: 0, posted_credit: 0, posted_debit: 0}
             } = Instance.validate_account_balances(inst)
    end

    test "it works for balanced accounts", %{instance: inst} = ctx do
      create_transaction(ctx)
      create_transaction(ctx, :posted)

      assert {
               :ok,
               %{pending_credit: 100, pending_debit: 100, posted_credit: 100, posted_debit: 100}
             } = Instance.validate_account_balances(inst)
    end
  end
end
