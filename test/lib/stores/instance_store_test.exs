defmodule DoubleEntryLedger.InstanceStoreTest do
  @moduledoc """
  This module tests the InstanceStore behaviour.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.TransactionFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.InstanceStore

  doctest InstanceStore

  describe "sum_accounts_debits_and_credits_by_currency" do
    setup [:create_instance]

    test "it works for empty accounts", %{instance: inst} do
      assert {
               :ok,
               []
             } = InstanceStore.sum_accounts_debits_and_credits_by_currency(inst.id)
    end

    test "it works for balanced accounts", %{instance: inst} = ctx do
      new_ctx = create_accounts(ctx)
      create_transaction(new_ctx)
      create_transaction(new_ctx, :posted)

      assert {
               :ok,
               [
                 %{
                   currency: :EUR,
                   pending_credit: 100,
                   pending_debit: 100,
                   posted_credit: 100,
                   posted_debit: 100
                 }
               ]
             } = InstanceStore.sum_accounts_debits_and_credits_by_currency(inst.id)
    end
  end
end
