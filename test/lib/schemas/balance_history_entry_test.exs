defmodule BalanceHistoryEntryTest do
  @moduledoc """
  This module tests the BalanceHistoryEntry module.
  """
  use ExUnit.Case, async: true
  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures}
  alias DoubleEntryLedger.{Account, Entry, BalanceHistoryEntry, Balance}

  describe "build_from_account_changeset/1" do
    setup [:create_instance]

    test "builds a balance history entry from an account changeset", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, type: :asset)
      entry = %Entry{account_id: account.id, value: %Money{amount: 100, currency: :EUR}, type: :debit }
      account_changeset = Account.update_balances(account, %{entry: entry, trx: :posted})

      balance_history_entry = BalanceHistoryEntry.build_from_account_changeset(account_changeset)
      assert Changeset.get_embed(balance_history_entry, :posted, :struct) == %Balance{amount: 100, credit: 0, debit: 100}
      assert Changeset.get_embed(balance_history_entry, :pending, :struct) == %Balance{amount: 0, credit: 0, debit: 0}
      assert Changeset.get_change(balance_history_entry, :available, :struct) == 100
      assert Changeset.get_change(balance_history_entry, :account_id) == account.id
    end
  end
end
