defmodule DoubleEntryLedger.TransactionStoreTest do
  @moduledoc """
  This module tests the TransactionStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures, TransactionFixtures}
  alias DoubleEntryLedger.{Account, TransactionStore, Balance, Repo}

  describe "create/1" do

    setup [:create_instance, :create_accounts]

    test "create transaction with 2 accounts", %{accounts: [a1, a2, _, _]} = ctx do
      create_transaction(ctx)

      assert %{
        pending: %Balance{amount: -100, credit: 0, debit: 100 },
        posted: %Balance{amount: 0, credit: 0, debit: 0 },
        available: 0,
        type: :debit,
      } = Repo.get!(Account, a1.id)
      assert %{
        pending: %Balance{amount: -100, credit: 100, debit: 0 },
        posted: %Balance{amount: 0, credit: 0, debit: 0 },
        available: 0,
        type: :credit,
      } = Repo.get!(Account, a2.id)
    end

    test "create transaction with 3 accounts", %{instance: inst, accounts: [a1, a2, a3, _]} do
      attr = transaction_attr(status: :posted,
        instance_id: inst.id, entries: [
          %{type: :debit, value: Money.new(50, :EUR), account_id: a1.id},
          %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id},
          %{type: :debit, value: Money.new(50, :EUR), account_id: a3.id},
          ])
      TransactionStore.create(attr)

      assert %{
               posted: %Balance{amount: 50, credit: 0, debit: 50 },
               pending: %Balance{amount: 0, credit: 0, debit: 0 },
               available: 50,
               type: :debit,
             } = Repo.get!(Account, a1.id)
      assert %{
               posted: %Balance{amount: 50, credit: 0, debit: 50 },
               pending: %Balance{amount: 0, credit: 0, debit: 0 },
               available: 50,
               type: :debit,
             } = Repo.get!(Account, a3.id)
      assert %{
               posted: %Balance{amount: 100, credit: 100, debit: 0 },
               pending: %Balance{amount: 0, credit: 0, debit: 0 },
               available: 100,
               type: :credit,
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
        pending: %Balance{amount: 0, credit: 0, debit: 0 },
        posted: %Balance{amount: 100, credit: 0, debit: 100 },
        available: 100, type: :debit,
      } = Repo.get!(Account, a1.id)
      assert %{
        pending: %Balance{amount: 0, credit: 0, debit: 0 },
        posted: %Balance{amount: 100, credit: 100, debit: 0 },
        available: 100, type: :credit,
      } = Repo.get!(Account, a2.id)
    end

    test "pending_to_posted update with changing entries", %{accounts: [a1, a2, _, _]} = ctx do
      %{transaction: trx} = create_transaction(ctx)
      TransactionStore.update(trx, %{status: :posted, entries: [
        %{type: :debit, value: Money.new(50, :EUR), account_id: a1.id},
        %{type: :credit, value: Money.new(50, :EUR), account_id: a2.id}
      ]})

      assert %{status: :posted} = Repo.reload(trx)
      assert %{
        pending: %Balance{amount: 0, credit: 0, debit: 0 },
        posted: %Balance{amount: 50, credit: 0, debit: 50 },
        available: 50, type: :debit,
      } = Repo.get!(Account, a1.id)
      assert %{
        pending: %Balance{amount: 0, credit: 0, debit: 0 },
        posted: %Balance{amount: 50, credit: 50, debit: 0 },
        available: 50, type: :credit,
      } = Repo.get!(Account, a2.id)
    end

    test "pending_to_posted update with changing entries that are too big for the accounts", %{instance: inst, accounts: [_, _, a1, a2]} do
      attr = transaction_attr(instance_id: inst.id, status: :posted, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
      ])
      {:ok, _} = TransactionStore.create(attr) # posted transaction to create balances
      {:ok, trx } = TransactionStore.create(transaction_attr(
        instance_id: inst.id, status: :pending, entries: [
          %{type: :credit, value: Money.new(50, :EUR), account_id: a1.id},
          %{type: :debit, value: Money.new(50, :EUR), account_id: a2.id}
        ])) # pending transaction to update
      TransactionStore.update(trx, %{status: :posted, entries: [
        %{type: :credit, value: Money.new(150, :EUR), account_id: a1.id},
        %{type: :debit, value: Money.new(150, :EUR), account_id: a2.id}
      ]}) # update pending transaction with values that are too big for the accounts

      assert %{status: :pending} = Repo.reload(trx) # transaction should still be pending
      assert %{
        pending: %Balance{amount: 50, credit: 50, debit: 0 },
        posted: %Balance{amount: 100, credit: 0, debit: 100 },
        available: 50, type: :debit,
      } = Repo.get!(Account, a1.id)  # accounts should have the original values from the pending transaction
      assert %{
        pending: %Balance{amount: 50, credit: 0, debit: 50 },
        posted: %Balance{amount: 100, credit: 100, debit: 0 },
        available: 50, type: :credit,
      } = Repo.get!(Account, a2.id)
    end


    test "simple pending_to_archived update", %{accounts: [a1, a2, _, _]} = ctx do
      %{transaction: trx} = create_transaction(ctx)
      TransactionStore.update(trx, %{status: :archived})

      assert %{status: :archived} = Repo.reload(trx)
      assert %{
        pending: %Balance{amount: 0, credit: 0, debit: 0 },
        posted: %Balance{amount: 0, credit: 0, debit: 0 },
        available: 0, type: :debit,
      } = Repo.get!(Account, a1.id)
      assert %{
        pending: %Balance{amount: 0, credit: 0, debit: 0 },
        posted: %Balance{amount: 0, credit: 0, debit: 0 },
        available: 0, type: :credit,
      } = Repo.get!(Account, a2.id)
    end
  end
end
