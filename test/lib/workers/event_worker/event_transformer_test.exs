defmodule DoubleEntryLedger.EventTransformerTest do
  @moduledoc """
  This module tests the EventTransformer.
  """

  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.EventWorker.EventTransformer
  alias DoubleEntryLedger.Event.{EntryData, TransactionData}
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  doctest EventTransformer

  describe "transaction_data_to_transaction_map/2" do
    setup [:create_instance, :create_accounts]

    test "converts transaction data to transaction map", %{
      instance: instance,
      accounts: [a1, a2, _, _]
    } do
      entries = [
        %EntryData{account_id: a1.id, amount: 100, currency: "EUR"},
        %EntryData{account_id: a2.id, amount: 100, currency: "EUR"}
      ]

      transaction_data = %TransactionData{entries: entries, status: :posted}

      {:ok, transaction_map} =
        EventTransformer.transaction_data_to_transaction_map(transaction_data, instance.id)

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
        %EntryData{account_id: a1.id, amount: -100, currency: "EUR"},
        %EntryData{account_id: a2.id, amount: -100, currency: "EUR"}
      ]

      transaction_data = %TransactionData{entries: entries, status: :posted}

      {:ok, transaction_map} =
        EventTransformer.transaction_data_to_transaction_map(transaction_data, instance.id)

      assert MapSet.new([
               %{account_id: a1.id, value: %Money{amount: 100, currency: :EUR}, type: :credit},
               %{account_id: a2.id, value: %Money{amount: 100, currency: :EUR}, type: :debit}
             ]) == MapSet.new(transaction_map.entries)
    end

    test "it works for empty entries", %{instance: instance} do
      transaction_data = %TransactionData{status: :posted}

      {:ok, transaction_map} =
        EventTransformer.transaction_data_to_transaction_map(transaction_data, instance.id)

      assert !Map.has_key?(transaction_map, :entries)
    end
  end
end
