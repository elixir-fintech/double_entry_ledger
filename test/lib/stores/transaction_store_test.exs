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
          %{type: :debit, amount: Money.new(50, :EUR), account_id: a1.id},
          %{type: :credit, amount: Money.new(100, :EUR), account_id: a2.id},
          %{type: :debit, amount: Money.new(50, :EUR), account_id: a3.id},
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
      {:ok, trx} = create_transaction(ctx)
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

    @tag :skip
    test "pending_to_posted update with changing entries", %{accounts: [a1, a2, _, _]} = ctx do
      {:ok, trx} = create_transaction(ctx)
      TransactionStore.update(trx, %{status: :posted, entries: [
        %{type: :debit, amount: Money.new(50, :EUR), account_id: a1.id},
        %{type: :credit, amount: Money.new(50, :EUR), account_id: a2.id}
      ]})

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

    test "simple pending_to_archived update", %{accounts: [a1, a2, _, _]} = ctx do
      {:ok, trx} = create_transaction(ctx)
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

  defp create_transaction(%{instance: inst, accounts: [a1, a2, _, _ ]}) do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, amount: Money.new(100, :EUR), account_id: a1.id},
        %{type: :credit, amount: Money.new(100, :EUR), account_id: a2.id}
      ])
      TransactionStore.create(attr)
  end
end
