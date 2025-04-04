defmodule DoubleEntryLedger.AccountStoreTest do
  @moduledoc """
  This module tests the AccountStore behaviour.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.AccountStore

  doctest AccountStore

  describe "get_accounts_by_instance_id" do
    setup [:create_instance]

    test "returns accounts with given ids", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]

      {:ok, returned_accounts} =
        AccountStore.get_accounts_by_instance_id(instance.id, Enum.map(accounts, & &1.id))

      assert MapSet.new(accounts) == MapSet.new(returned_accounts)
    end

    test "returns error when some accounts are not found", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]

      account_ids = [instance.id | Enum.map(accounts, & &1.id)]

      assert {:error, "Some accounts were not found"} ==
               AccountStore.get_accounts_by_instance_id(instance.id, account_ids)
    end
  end

  describe "get_all_accounts_by_instance_id" do
    setup [:create_instance]

    test "returns accounts with given instance id", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]

      {:ok, returned_accounts} = AccountStore.get_all_accounts_by_instance_id(instance.id)
      assert MapSet.new(accounts) == MapSet.new(returned_accounts)
    end

    test "returns error when no accounts are found", %{instance: instance} do
      assert {:error, "No accounts were found"} ==
               AccountStore.get_all_accounts_by_instance_id(instance.id)
    end
  end
end
