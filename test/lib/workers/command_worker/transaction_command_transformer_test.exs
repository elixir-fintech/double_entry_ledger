defmodule DoubleEntryLedger.TransactionCommandTransformerTest do
  @moduledoc """
  This module tests the TransactionCommandTransformer.
  """

  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Workers.CommandWorker.TransactionCommandTransformer
  alias DoubleEntryLedger.Command.{EntryData, TransactionData}
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  doctest TransactionCommandTransformer

  describe "transaction_data_to_transaction_map/2" do
    setup [:create_instance, :create_accounts]

    test "converts transaction data to transaction map", %{
      instance: instance,
      accounts: [a1, a2, _, _]
    } do
      entries = [
        %EntryData{account_address: a1.address, amount: 100, currency: "EUR"},
        %EntryData{account_address: a2.address, amount: 100, currency: "EUR"}
      ]

      transaction_data = %TransactionData{entries: entries, status: :posted}

      {:ok, transaction_map} =
        TransactionCommandTransformer.transaction_data_to_transaction_map(
          transaction_data,
          instance.id
        )

      assert MapSet.new([
               %{account_id: a1.id, value: %Money{amount: 100, currency: :EUR}, type: :debit},
               %{account_id: a2.id, value: %Money{amount: 100, currency: :EUR}, type: :credit}
             ]) == MapSet.new(transaction_map.entries)

      assert transaction_map.instance_id == instance.id
      assert transaction_map.status == :posted
      assert Enum.count(transaction_map.entries) == 2
    end

    test "negative turns into positive with correct entry type", %{
      instance: instance,
      accounts: [a1, a2, _, _]
    } do
      entries = [
        %EntryData{account_address: a1.address, amount: -100, currency: "EUR"},
        %EntryData{account_address: a2.address, amount: -100, currency: "EUR"}
      ]

      transaction_data = %TransactionData{entries: entries, status: :posted}

      {:ok, transaction_map} =
        TransactionCommandTransformer.transaction_data_to_transaction_map(
          transaction_data,
          instance.id
        )

      assert MapSet.new([
               %{account_id: a1.id, value: %Money{amount: 100, currency: :EUR}, type: :credit},
               %{account_id: a2.id, value: %Money{amount: 100, currency: :EUR}, type: :debit}
             ]) == MapSet.new(transaction_map.entries)
    end

    test "it works for empty entries", %{instance: instance} do
      transaction_data = %TransactionData{status: :posted}

      {:ok, transaction_map} =
        TransactionCommandTransformer.transaction_data_to_transaction_map(
          transaction_data,
          instance.id
        )

      assert !Map.has_key?(transaction_map, :entries)
    end

    test "returns error for non-existing accounts", %{instance: instance} do
      entries = [
        %EntryData{account_address: "xyz", amount: 100, currency: "EUR"},
        %EntryData{account_address: "abc", amount: 100, currency: "EUR"}
      ]

      transaction_data = %TransactionData{entries: entries, status: :posted}

      assert {:error, :no_accounts_found} =
               TransactionCommandTransformer.transaction_data_to_transaction_map(
                 transaction_data,
                 instance.id
               )
    end

    test "returns error for mismatched accounts and entries", %{
      instance: instance,
      accounts: [a1, _, _, _]
    } do
      entries = [
        %EntryData{account_address: a1.address, amount: 100, currency: "EUR"},
        %EntryData{account_address: "xyz", amount: 100, currency: "EUR"}
      ]

      transaction_data = %TransactionData{entries: entries, status: :posted}

      assert {:error, :some_accounts_not_found} =
               TransactionCommandTransformer.transaction_data_to_transaction_map(
                 transaction_data,
                 instance.id
               )
    end

    test "returns error for incomplete entry data", %{
      instance: instance,
      accounts: [a1, a2, _, _]
    } do
      entries = [
        %EntryData{account_address: a1.address, currency: "EUR", amount: 100},
        %EntryData{account_address: a2.address, amount: 100}
      ]

      transaction_data = %TransactionData{status: :posted, entries: entries}

      assert {:error, :invalid_entry_data} =
               TransactionCommandTransformer.transaction_data_to_transaction_map(
                 transaction_data,
                 instance.id
               )
    end
  end
end
