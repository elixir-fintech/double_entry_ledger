defmodule DoubleEntryLedger.InstanceStoreTest do
  @moduledoc """
  This module tests the InstanceStore behaviour.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.TransactionFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.{InstanceStore, TransactionStore}

  doctest InstanceStore

  describe "sum_accounts_debits_and_credits_by_currency" do
    setup [:create_instance]

    test "it works for empty accounts", %{instance: inst } do
      assert {
        :ok, []
      } = InstanceStore.sum_accounts_debits_and_credits_by_currency(inst.id)
    end

    test "it works for balanced accounts", %{instance: inst} = ctx do
      %{accounts: [a1, a2, a3, _]} = create_accounts(ctx)
      attr = transaction_attr(status: :posted,
        instance_id: inst.id, entries: [
          %{type: :debit, value: Money.new(50, :EUR), account_id:  a1.id},
          %{type: :credit, value: Money.new(100, :EUR), account_id:  a2.id},
          %{type: :debit, value: Money.new(50, :EUR), account_id:  a3.id},
      ])
      attr2 = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(10, :EUR), account_id:  a1.id},
        %{type: :credit, value: Money.new(40, :EUR), account_id:  a2.id},
        %{type: :debit, value: Money.new(30, :EUR), account_id:  a3.id},
      ])

      TransactionStore.create(attr)
      TransactionStore.create(attr2)
      assert {
        :ok,
        [%{currency: :EUR, pending_credit: 40, pending_debit: 40, posted_credit: 100, posted_debit: 100}]
      } = InstanceStore.sum_accounts_debits_and_credits_by_currency(inst.id)
    end
  end
end
