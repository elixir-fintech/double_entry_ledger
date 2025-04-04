defmodule DoubleEntryLedger.TransactionStoreTest do
  @moduledoc """
  This module tests the TransactionStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import Mox

  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures, TransactionFixtures}
  alias DoubleEntryLedger.{Account, TransactionStore, Balance, Repo}
  alias Ecto.Multi

  describe "create/1" do
    setup [:create_instance, :create_accounts]

    test "create transaction with 2 accounts", %{accounts: [a1, a2, _, _]} = ctx do
      create_transaction(ctx)

      assert %{
               pending: %Balance{amount: -100, credit: 0, debit: 100},
               posted: %Balance{amount: 0, credit: 0, debit: 0},
               available: 0,
               normal_balance: :debit
             } = Repo.get!(Account, a1.id)

      assert %{
               pending: %Balance{amount: -100, credit: 100, debit: 0},
               posted: %Balance{amount: 0, credit: 0, debit: 0},
               available: 0,
               normal_balance: :credit
             } = Repo.get!(Account, a2.id)
    end

    test "create transaction with 3 accounts", %{instance: inst, accounts: [a1, a2, a3, _]} do
      attr =
        transaction_attr(
          status: :posted,
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(50, :EUR), account_id: a1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id},
            %{type: :debit, value: Money.new(50, :EUR), account_id: a3.id}
          ]
        )

      TransactionStore.create(attr)

      assert %{
               posted: %Balance{amount: 50, credit: 0, debit: 50},
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               available: 50,
               normal_balance: :debit
             } = Repo.get!(Account, a1.id)

      assert %{
               posted: %Balance{amount: 50, credit: 0, debit: 50},
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               available: 50,
               normal_balance: :debit
             } = Repo.get!(Account, a3.id)

      assert %{
               posted: %Balance{amount: 100, credit: 100, debit: 0},
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               available: 100,
               normal_balance: :credit
             } = Repo.get!(Account, a2.id)
    end
  end

  describe "update/2" do
    setup [:create_instance, :create_accounts]

    test "simple pending_to_posted update", %{accounts: [a1, a2, _, _]} = ctx do
      %{transaction: trx} = create_transaction(ctx)
      TransactionStore.update(trx, %{status: :posted})

      assert %{status: :posted} = Repo.reload(trx)

      assert %{
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               posted: %Balance{amount: 100, credit: 0, debit: 100},
               available: 100,
               normal_balance: :debit
             } = Repo.get!(Account, a1.id)

      assert %{
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               posted: %Balance{amount: 100, credit: 100, debit: 0},
               available: 100,
               normal_balance: :credit
             } = Repo.get!(Account, a2.id)
    end

    test "pending_to_posted update with changing entries", %{accounts: [a1, a2, _, _]} = ctx do
      %{transaction: trx} = create_transaction(ctx)

      TransactionStore.update(trx, %{
        status: :posted,
        entries: [
          %{type: :debit, value: Money.new(50, :EUR), account_id: a1.id},
          %{type: :credit, value: Money.new(50, :EUR), account_id: a2.id}
        ]
      })

      assert %{status: :posted} = Repo.reload(trx)

      assert %{
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               posted: %Balance{amount: 50, credit: 0, debit: 50},
               available: 50,
               normal_balance: :debit
             } = Repo.get!(Account, a1.id)

      assert %{
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               posted: %Balance{amount: 50, credit: 50, debit: 0},
               available: 50,
               normal_balance: :credit
             } = Repo.get!(Account, a2.id)
    end

    test "pending_to_posted update with changing entries that are too big for the accounts", %{
      instance: inst,
      accounts: [_, _, a1, a2]
    } do
      attr =
        transaction_attr(
          instance_id: inst.id,
          status: :posted,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
          ]
        )

      # posted transaction to create balances
      {:ok, _} = TransactionStore.create(attr)

      {:ok, trx} =
        TransactionStore.create(
          transaction_attr(
            instance_id: inst.id,
            status: :pending,
            entries: [
              %{type: :credit, value: Money.new(50, :EUR), account_id: a1.id},
              %{type: :debit, value: Money.new(50, :EUR), account_id: a2.id}
            ]
          )
        )

      # pending transaction to update
      TransactionStore.update(trx, %{
        status: :posted,
        entries: [
          %{type: :credit, value: Money.new(150, :EUR), account_id: a1.id},
          %{type: :debit, value: Money.new(150, :EUR), account_id: a2.id}
        ]
      })

      # update pending transaction with values that are too big for the accounts

      # transaction should still be pending
      assert %{status: :pending} = Repo.reload(trx)
      # accounts should have the original values from the pending transaction
      assert %{
               pending: %Balance{amount: 50, credit: 50, debit: 0},
               posted: %Balance{amount: 100, credit: 0, debit: 100},
               available: 50,
               normal_balance: :debit
             } = Repo.get!(Account, a1.id)

      assert %{
               pending: %Balance{amount: 50, credit: 0, debit: 50},
               posted: %Balance{amount: 100, credit: 100, debit: 0},
               available: 50,
               normal_balance: :credit
             } = Repo.get!(Account, a2.id)
    end

    test "simple pending_to_archived update", %{accounts: [a1, a2, _, _]} = ctx do
      %{transaction: trx} = create_transaction(ctx)
      TransactionStore.update(trx, %{status: :archived})

      assert %{status: :archived} = Repo.reload(trx)

      assert %{
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               posted: %Balance{amount: 0, credit: 0, debit: 0},
               available: 0,
               normal_balance: :debit
             } = Repo.get!(Account, a1.id)

      assert %{
               pending: %Balance{amount: 0, credit: 0, debit: 0},
               posted: %Balance{amount: 0, credit: 0, debit: 0},
               available: 0,
               normal_balance: :credit
             } = Repo.get!(Account, a2.id)
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
               |> TransactionStore.build_create(:transaction, attr, DoubleEntryLedger.MockRepo)
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
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Multi.new()
               |> TransactionStore.build_update(
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
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Multi.new()
               |> Multi.run(:create_event_trx, fn _repo, _changes -> {:ok, trx} end)
               |> TransactionStore.build_update(
                 :transaction,
                 :create_event_trx,
                 %{status: :posted},
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end
  end
end
