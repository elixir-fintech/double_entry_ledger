defmodule DoubleEntryLedger.AccountTest do
  @moduledoc """
  This module provides tests for the Account module.
  """

  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Account, Balance}

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  doctest Account

  describe "accounts" do
    setup [:create_instance]

    test "returns error changeset for missing fields", _ctx do
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          name: {"can't be blank", [validation: :required]},
          type: {"can't be blank", [validation: :required]},
          instance_id: {"can't be blank", [validation: :required]}
        ]
      } = Account.changeset(%Account{}, %{})
    end

    test "fixture", %{instance: inst} do
      inst_id = inst.id
      assert %Account{
        name: "some name",
        description: "some description",
        currency: :EUR,
        type: :debit,
        context: %{},
        posted: %Balance{amount: 0, debit: 0, credit: 0},
        pending: %Balance{amount: 0, debit: 0, credit: 0},
        available: 0,
        instance_id: ^inst_id,
      } = account_fixture(instance_id: inst.id)
    end
  end

  describe "update balances debit account: trx = posted" do
    setup [:create_instance]

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :debit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :debit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 100,
          posted: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: 100, debit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :debit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :credit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          posted: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: -100, credit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end
  end

  describe "update balances debit account: trx = pending" do
    setup [:create_instance]

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :debit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :debit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          pending: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: -100, debit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :debit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :credit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          pending: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: 100, credit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances debit account allowed_negative: false" do
    setup [:create_instance]

    test "credit entry trx: posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :debit, allowed_negative: false)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :credit }

      assert %Ecto.Changeset{
        valid?: false,
        errors: [available: {"amount can't be negative", []}],
      } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry trx: pending", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :debit, allowed_negative: false)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :credit }

      assert %Ecto.Changeset{
        valid?: false,
        errors: [available: {"amount can't be negative", []}],
      } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances credit account: trx = posted" do
    setup [:create_instance]

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :credit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :credit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 100,
          posted: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: 100, credit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :credit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :debit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          posted: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: -100, debit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end
  end

  describe "update balances credit account: trx = pending" do
    setup [:create_instance]

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :credit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :debit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          pending: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: 100, debit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :credit)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :credit }

      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          pending: %Ecto.Changeset{
            valid?: true,
            changes: %{amount: -100, credit: 100}}}
      } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances credit account allowed_negative: false" do
    setup [:create_instance]

    test "credit entry trx: posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :credit, allowed_negative: false)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :debit }

      assert %Ecto.Changeset{
        valid?: false,
        errors: [available: {"amount can't be negative", []}],
      } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry trx: pending", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :credit, allowed_negative: false)
      entry = %{account: account, amount: %Money{amount: 100, currency: :EUR}, type: :debit }

      assert %Ecto.Changeset{
        valid?: false,
        errors: [available: {"amount can't be negative", []}],
      } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end
end
