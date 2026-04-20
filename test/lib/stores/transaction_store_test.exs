defmodule DoubleEntryLedger.Stores.TransactionStoreTest do
  @moduledoc """
  This module tests the TransactionStore and TransactionStoreHelper module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import Mox

  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures, TransactionFixtures}
  alias DoubleEntryLedger.Repo

  alias DoubleEntryLedger.Stores.{
    TransactionStore,
    TransactionStoreHelper,
    InstanceStore,
    AccountStore
  }

  alias Ecto.Multi

  doctest TransactionStore
  doctest TransactionStoreHelper

  describe "create/3" do
    setup [:create_instance, :create_accounts]

    test "successfully creates a transaction", %{
      instance: inst,
      accounts: [a1, a2, _, _]
    } do
      attrs = %{
        status: :pending,
        entries: [
          %{currency: "EUR", amount: 100, account_address: a1.address},
          %{currency: "EUR", amount: 100, account_address: a2.address}
        ]
      }

      assert {:ok, _trx} = TransactionStore.create(inst.address, attrs, "idempotent")
    end
  end

  describe "build_create/4" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "can handle StaleEntryError so the multi step returns a Multi.failure()", %{
      instance: inst,
      accounts: [a1, a2, _, _]
    } do
      attr =
        transaction_attr(
          status: :pending,
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
          ]
        )

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn _changeset ->
        raise Ecto.StaleEntryError, action: :insert, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Ecto.Multi.new()
               |> TransactionStoreHelper.build_create(
                 :transaction,
                 attr,
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end
  end

  describe "build_update/5" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "with transaction, can handle StaleEntryError so the multi step returns a Multi.failure()",
         ctx do
      %{transaction: trx} = create_transaction(ctx, :pending)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Multi.new()
               |> TransactionStoreHelper.build_update(
                 :transaction,
                 trx,
                 %{status: :posted},
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end

    test "with transaction_step, can handle StaleEntryError so the multi step returns a Multi.failure()",
         ctx do
      %{transaction: trx} = create_transaction(ctx, :pending)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Multi.new()
               |> Multi.run(:create_command_trx, fn _repo, _changes -> {:ok, trx} end)
               |> TransactionStoreHelper.build_update(
                 :transaction,
                 :create_command_trx,
                 %{status: :posted},
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end
  end

  describe "list_for_instance/2" do
    setup [:create_instance, :create_accounts]

    test "returns transactions for the instance", %{instance: instance, accounts: [a1, a2 | _]} do
      attrs = %{
        status: :posted,
        entries: [
          %{account_address: a1.address, amount: 100, currency: :EUR},
          %{account_address: a2.address, amount: 100, currency: :EUR}
        ]
      }

      {:ok, trx} = TransactionStore.create(instance.address, attrs, "idem-1")

      assert {:ok, {[%{id: id}], %Flop.Meta{}}} = TransactionStore.list_for_instance(instance)
      assert id == trx.id
    end

    test "accepts UUID string for scope arg", %{instance: instance, accounts: [a1, a2 | _]} do
      attrs = %{
        status: :posted,
        entries: [
          %{account_address: a1.address, amount: 100, currency: :EUR},
          %{account_address: a2.address, amount: 100, currency: :EUR}
        ]
      }

      {:ok, _} = TransactionStore.create(instance.address, attrs, "idem-2")

      {:ok, {by_struct, _}} = TransactionStore.list_for_instance(instance)
      {:ok, {by_id, _}} = TransactionStore.list_for_instance(instance.id)

      assert Enum.map(by_struct, & &1.id) == Enum.map(by_id, & &1.id)
    end

    test "filters by status", %{instance: instance, accounts: [a1, a2 | _]} do
      pending_attrs = %{
        status: :pending,
        entries: [
          %{account_address: a1.address, amount: 10, currency: :EUR},
          %{account_address: a2.address, amount: 10, currency: :EUR}
        ]
      }

      posted_attrs = %{pending_attrs | status: :posted}

      {:ok, pending} = TransactionStore.create(instance.address, pending_attrs, "idem-p")
      {:ok, _posted} = TransactionStore.create(instance.address, posted_attrs, "idem-x")

      assert {:ok, {[%{id: id}], _meta}} =
               TransactionStore.list_for_instance(instance, %{
                 filters: [%{field: :status, op: :==, value: :pending}]
               })

      assert id == pending.id
    end

    test "rejects non-allow-listed filter", %{instance: instance} do
      assert {:error, %Flop.Meta{errors: errors}} =
               TransactionStore.list_for_instance(instance, %{
                 filters: [%{field: :instance_id, op: :==, value: instance.id}]
               })

      refute errors == []
    end
  end

  describe "list_for_instance_and_account/3" do
    setup [:create_instance, :create_accounts]

    test "returns tuples for the scoped account", ctx do
      %{instance: inst, accounts: [a1, a2 | _]} = ctx

      attrs = %{
        status: :posted,
        entries: [
          %{account_address: a1.address, amount: 100, currency: :EUR},
          %{account_address: a2.address, amount: 100, currency: :EUR}
        ]
      }

      {:ok, _} = TransactionStore.create(inst.address, attrs, "idem-t")

      assert {:ok, {[{trx, acc, _entry, bh}], %Flop.Meta{}}} =
               TransactionStore.list_for_instance_and_account(inst, a1)

      assert acc.id == a1.id
      assert trx.instance_id == inst.id
      assert bh.available == 100
    end

    test "accepts UUID strings for both scope args", ctx do
      %{instance: inst, accounts: [a1, a2 | _]} = ctx

      attrs = %{
        status: :posted,
        entries: [
          %{account_address: a1.address, amount: 100, currency: :EUR},
          %{account_address: a2.address, amount: 100, currency: :EUR}
        ]
      }

      {:ok, _} = TransactionStore.create(inst.address, attrs, "idem-u")

      {:ok, {via_struct, _}} = TransactionStore.list_for_instance_and_account(inst, a1)
      {:ok, {via_id, _}} = TransactionStore.list_for_instance_and_account(inst.id, a1.id)

      assert length(via_struct) == length(via_id)
    end
  end
end
