defmodule DoubleEntryLedger.BalanceTest do
  @moduledoc """
  This module contains tests for the `DoubleEntryLedger.Balance` module. It ensures that the balance calculations and related functionalities are working as expected.
  """

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Balance

  doctest Balance

  describe "Balance: " do
    test "init" do
      balance = %Balance{}
      assert %Balance{amount: 0, debit: 0, credit: 0} = balance
    end
  end

  describe "Debit accounts balance: " do
    test "reverse_pending debit" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 50, debit: 50}} =
               Balance.reverse_pending(
                 %Balance{amount: 100, debit: 100, credit: 0},
                 50,
                 :debit,
                 :debit
               )
    end

    test "reverse_pending credit" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: -50, credit: 50}} =
               Balance.reverse_pending(
                 %Balance{amount: -100, debit: 0, credit: 100},
                 50,
                 :credit,
                 :debit
               )
    end

    test "update balance changeset entry_type == account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 100, debit: 100}} =
               Balance.update_balance(%Balance{}, 100, :debit, :debit)
    end

    test "update balance changeset with previous balance entry_type == account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 200, debit: 200}} =
               Balance.update_balance(
                 %Balance{amount: 100, credit: 0, debit: 100},
                 100,
                 :debit,
                 :debit
               )
    end

    test "update balance changeset entry_type != account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: -100, credit: 100}} =
               Balance.update_balance(%Balance{}, 100, :credit, :debit)
    end

    test "update balance changeset with previous balance entry_type != account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 50, credit: 50}} =
               Balance.update_balance(
                 %Balance{amount: 100, credit: 0, debit: 100},
                 50,
                 :credit,
                 :debit
               )
    end
  end

  describe "Credit accounts balance: " do
    test "update balance changeset entry_type == account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 100, credit: 100}} =
               Balance.update_balance(%Balance{}, 100, :credit, :credit)
    end

    test "update balance changeset with previous balance entry_type == account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 200, credit: 200}} =
               Balance.update_balance(
                 %Balance{amount: 100, debit: 0, credit: 100},
                 100,
                 :credit,
                 :credit
               )
    end

    test "update balance changeset entry_type != account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: -100, debit: 100}} =
               Balance.update_balance(%Balance{}, 100, :debit, :credit)
    end

    test "update balance changeset with previous balance entry_type != account_type" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 50, debit: 50}} =
               Balance.update_balance(
                 %Balance{amount: 100, credit: 100, debit: 0},
                 50,
                 :debit,
                 :credit
               )
    end

    test "reverse_pending credit" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: 50, credit: 50}} =
               Balance.reverse_pending(
                 %Balance{amount: 100, debit: 0, credit: 100},
                 50,
                 :credit,
                 :credit
               )
    end

    test "reverse_pending debit" do
      assert %Ecto.Changeset{valid?: true, changes: %{amount: -50, debit: 50}} =
               Balance.reverse_pending(
                 %Balance{amount: -100, debit: 100, credit: 0},
                 50,
                 :debit,
                 :credit
               )
    end
  end
end
