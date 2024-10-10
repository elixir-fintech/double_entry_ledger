defmodule DoubleEntryLedger.TransactionTest do
  @moduledoc """
  This module defines tests for the transaction
  """
  use DoubleEntryLedger.RepoCase
  alias DoubleEntryLedger.Transaction
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.TransactionFixtures

  doctest Transaction

  describe "transaction 2 entries" do
    setup [:create_instance, :create_accounts]

    test "no entries", %{instance: inst} do
      attr = transaction_attr(instance_id: inst.id)
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"no accounts found", []},
          entries: {"must have at least 2 entries", []},
        ]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "empty entries", ctx do
      attr = transaction_attr(instance_id: ctx.instance.id, entries: [])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"no accounts found", []},
          entries: {"must have at least 2 entries", []},
        ]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "one entry", %{instance: inst, accounts: [acc1, _, _, _]} do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id:  acc1.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have at least 2 entries", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "debit and credit entries:" do
    setup [:create_instance, :create_accounts]

    test "both debit entries", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :debit, amount: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have equal debit and credit", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "both credit entries", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :credit, amount: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have equal debit and credit", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "amount different", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(101, :EUR), account_id:  acc1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have equal debit and credit", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "same amount but different currency", %{instance: inst } do
      acc1 = account_fixture(instance_id: inst.id, type: :debit, currency: :EUR)
      acc2 = account_fixture(instance_id: inst.id, type: :credit, currency: :USD)
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"currency must be the same as account", []}]
     } = Transaction.changeset(%Transaction{}, attr)
    end

    test "same amount", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: true,
        errors: []
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "same amounts but different currencies", %{instance: inst } do
      acc1 = account_fixture(instance_id: inst.id, type: :debit, currency: :EUR)
      acc2 = account_fixture(instance_id: inst.id, type: :credit, currency: :USD)
      acc3 = account_fixture(instance_id: inst.id, type: :debit, currency: :EUR)
      acc4 = account_fixture(instance_id: inst.id, type: :credit, currency: :USD)
      attr = transaction_attr(instance_id: inst.id, entries: [
         %{type: :debit, amount: Money.new(50, :EUR), account_id:  acc1.id},
         %{type: :credit, amount: Money.new(100, :USD), account_id:  acc2.id},
         %{type: :credit, amount: Money.new(50, :EUR), account_id:  acc3.id},
         %{type: :debit, amount: Money.new(100, :USD), account_id:  acc4.id}
      ])
      assert %Ecto.Changeset{
        valid?: true,
        errors: []
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "accounts must be on the same ledger" do
    setup [:create_instance]

    test "on account on a different ledgers", ctx do
      instance2 = instance_fixture()
      a1 = account_fixture(instance_id: ctx.instance.id, type: :debit)
      a2 = account_fixture(instance_id: instance2.id, type: :credit)
      attr = transaction_attr(instance_id: ctx.instance.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id:  a1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id:  a2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"accounts must be on same ledger", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "all accounts on different ledgers", ctx do
      instance2 = instance_fixture()
      a1 = account_fixture(instance_id: ctx.instance.id, type: :debit)
      a2 = account_fixture(instance_id: ctx.instance.id, type: :credit)
      attr = transaction_attr(instance_id: instance2.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id: a1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id: a2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"accounts must be on same ledger", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "currency entry == currency account" do
    setup [:create_instance, :create_accounts]

    test "currency entry != currency account", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(100, :USD), account_id: acc1.id},
        %{type: :credit, amount: Money.new(100, :USD), account_id: acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"currency must be the same as account", []}]
      } = Transaction.changeset(%Transaction{}, attr)
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
