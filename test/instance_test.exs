defmodule DoubleEntryLedger.InstanceTest do
  @moduledoc """
  This module contains tests for the instance
  """
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Instance, Transaction, Repo}

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.TransactionFixtures

  describe "instances" do

    test "Name is only required field", _ctx do
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          name: {"can't be blank", [validation: :required]}
        ]
      } = Instance.changeset(%Instance{}, %{})
    end

    test "sets the config and metadata to empty maps at insert", _ctx do
      {:ok, instance } = Repo.insert(
        Instance.changeset(%Instance{}, %{name: "some name" }),
        returning: true
      )
      assert %Instance{
        config: %{},
        metadata: %{}
      } = instance
    end
  end

  describe "validate_account_balances" do
    setup [:create_instance, :create_accounts]

    test "it works for empty accounts", %{instance: inst } do
      assert {
        :ok,
        %{pending_credit: 0, pending_debit: 0, posted_credit: 0, posted_debit: 0}
      } = Instance.validate_account_balances(inst)
    end

    test "it works for balanced accounts", %{instance: inst, accounts: [a1, a2, a3, _]} do
      attr = transaction_attr(status: :posted,
        instance_id: inst.id, entries: [
          %{type: :debit, amount: Money.new(50, :EUR), account_id:  a1.id},
          %{type: :credit, amount: Money.new(100, :EUR), account_id:  a2.id},
          %{type: :debit, amount: Money.new(50, :EUR), account_id:  a3.id},
      ])
      attr2 = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(10, :EUR), account_id:  a1.id},
        %{type: :credit, amount: Money.new(40, :EUR), account_id:  a2.id},
        %{type: :debit, amount: Money.new(30, :EUR), account_id:  a3.id},
      ])

      Transaction.create(attr) |> Repo.transaction()
      Transaction.create(attr2) |> Repo.transaction()
      assert {
        :ok,
        %{pending_credit: 40, pending_debit: 40, posted_credit: 100, posted_debit: 100}
      } = Instance.validate_account_balances(inst)
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end

  defp create_accounts(%{instance: instance}) do
    %{instance: instance, accounts: [
      account_fixture(instance_id: instance.id, type: :debit),
      account_fixture(instance_id: instance.id, type: :credit),
      account_fixture(instance_id: instance.id, type: :debit),
      account_fixture(instance_id: instance.id, type: :credit)
    ]}
  end
end
