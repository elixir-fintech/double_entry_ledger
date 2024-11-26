defmodule BalanceHistoryEntryTest do
  @moduledoc """
  This module tests the BalanceHistoryEntry module.
  """
  use ExUnit.Case, async: true
  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase
  # import DoubleEntryLedger.{AccountFixtures, InstanceFixtures, TransactionFixtures}
  alias DoubleEntryLedger.{BalanceHistoryEntry, Balance}

  describe "build_from_account_changeset/1" do
    test "builds a balance history entry from an account changeset" do
      account_changeset = %Ecto.Changeset{
        changes: %{
          id: "account-id",
          available: 100,
          posted: %Balance{amount: 0, credit: 0, debit: 0} |> Changeset.change(),
        },
        data: %{pending: %Balance{amount: 0, credit: 0, debit: 0}},
        valid?: true
      }

      balance_history_entry = BalanceHistoryEntry.build_from_account_changeset(account_changeset)

      assert %Changeset{
        changes: %{
          account_id: "account-id",
          available: 100,
          posted: _,
          pending: _
        }
      } = balance_history_entry
    end
  end
end
