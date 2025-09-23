defmodule DoubleEntryLedger.AccountStoreTest do
  @moduledoc """
  This module tests the AccountStore behaviour.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.AccountStore
  alias DoubleEntryLedger.AccountStoreHelper

  doctest AccountStore
  doctest AccountStoreHelper

  describe "get_accounts_by_instance_id" do
    setup [:create_instance]

    test "returns accounts with given ids", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]

      {:ok, returned_accounts} =
        AccountStore.get_accounts_by_instance_id(instance.id, Enum.map(accounts, & &1.address))

      assert MapSet.new(accounts) == MapSet.new(returned_accounts)
    end

    test "returns error when some accounts are not found", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]

      account_addresses = [instance.address | Enum.map(accounts, & &1.address)]

      assert {:error, :some_accounts_not_found} ==
               AccountStore.get_accounts_by_instance_id(instance.id, account_addresses)
    end

    test "returns error when account_addresses do not match", %{instance: instance} do
      account_addresses = ["non:existing:#{:rand.uniform(1000)}", "non:existing:#{:rand.uniform(1000)}"]

      assert {:error, :no_accounts_found} ==
               AccountStore.get_accounts_by_instance_id(instance.id, account_addresses)
    end

    test "returns error when no account_ids provided", %{instance: instance} do
      assert {:error, :no_account_ids_provided} ==
               AccountStore.get_accounts_by_instance_id(instance.id, [])
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
      assert {:error, :no_accounts_found} ==
               AccountStore.get_all_accounts_by_instance_id(instance.id)
    end
  end

  describe "get_accounts_by_instance_id_and_type" do
    setup [:create_instance]

    test "returns accounts with given instance id", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]

      {:ok, returned_accounts} =
        AccountStore.get_accounts_by_instance_id_and_type(instance.id, :asset)

      assert MapSet.new(accounts) == MapSet.new(returned_accounts)
    end

    test "returns error when no accounts are found", %{instance: instance} do
      account_fixture(instance_id: instance.id, type: :liability)

      assert {:error, :no_accounts_found_for_provided_type} ==
               AccountStore.get_accounts_by_instance_id_and_type(instance.id, :asset)
    end
  end
end
