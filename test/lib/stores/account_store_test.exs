defmodule DoubleEntryLedger.Stores.AccountStoreTest do
  @moduledoc """
  This module tests the AccountStore behaviour.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Stores.{
    AccountStore,
    InstanceStore,
    AccountStoreHelper
  }

  alias DoubleEntryLedger.Account
  alias DoubleEntryLedger.Command.AccountData

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
      account_addresses = [
        "non:existing:#{:rand.uniform(1000)}",
        "non:existing:#{:rand.uniform(1000)}"
      ]

      assert {:error, :no_accounts_found} ==
               AccountStore.get_accounts_by_instance_id(instance.id, account_addresses)
    end

    test "returns error when no account_ids provided", %{instance: instance} do
      assert {:error, :no_accounts_provided} ==
               AccountStore.get_accounts_by_instance_id(instance.id, [])
    end
  end

  describe "list_for_instance/2" do
    setup [:create_instance]

    test "returns accounts for the instance with default cursor meta", %{instance: instance} do
      a1 = account_fixture(instance_id: instance.id)
      a2 = account_fixture(instance_id: instance.id)

      assert {:ok, {accounts, %Flop.Meta{}}} = AccountStore.list_for_instance(instance)
      assert MapSet.new(Enum.map(accounts, & &1.id)) == MapSet.new([a1.id, a2.id])
    end

    test "accepts UUID string for scope arg", %{instance: instance} do
      _ = account_fixture(instance_id: instance.id)

      {:ok, {by_struct, _}} = AccountStore.list_for_instance(instance)
      {:ok, {by_id, _}} = AccountStore.list_for_instance(instance.id)

      assert Enum.map(by_struct, & &1.id) == Enum.map(by_id, & &1.id)
    end

    test "filters by type via allow-listed filter", %{instance: instance} do
      %{id: asset_id} = account_fixture(instance_id: instance.id, type: :asset)
      _ = account_fixture(instance_id: instance.id, type: :liability)

      assert {:ok, {[%{id: ^asset_id}], _meta}} =
               AccountStore.list_for_instance(instance, %{
                 filters: [%{field: :type, op: :==, value: :asset}]
               })
    end

    test "rejects non-allow-listed filter field", %{instance: instance} do
      assert {:error, %Flop.Meta{errors: errors}} =
               AccountStore.list_for_instance(instance, %{
                 filters: [%{field: :name, op: :==, value: "anything"}]
               })

      refute errors == []
    end

    test "cursor pagination with first/after", %{instance: instance} do
      for i <- 1..4 do
        account_fixture(instance_id: instance.id, address: "account:#{i}")
      end

      {:ok, {page_1, meta_1}} = AccountStore.list_for_instance(instance, %{first: 2})
      assert length(page_1) == 2
      assert meta_1.has_next_page? == true

      {:ok, {page_2, _}} =
        AccountStore.list_for_instance(instance, %{first: 2, after: meta_1.end_cursor})

      page_1_ids = Enum.map(page_1, & &1.id)
      page_2_ids = Enum.map(page_2, & &1.id)
      assert page_1_ids -- page_2_ids == page_1_ids
    end
  end

  describe "list_for_instance_address/2" do
    setup [:create_instance]

    test "returns accounts for the instance address", %{instance: instance} do
      a1 = account_fixture(instance_id: instance.id)

      assert {:ok, {[%{id: id}], _meta}} = AccountStore.list_for_instance_address(instance.address)
      assert id == a1.id
    end

    test "returns empty page for unknown instance address" do
      assert {:ok, {[], _meta}} = AccountStore.list_for_instance_address("no:such:instance")
    end
  end

  describe "list_balance_history/2" do
    setup [:create_instance]

    test "returns empty page for account with no history", %{instance: instance} do
      account = account_fixture(instance_id: instance.id)

      assert {:ok, {[], %Flop.Meta{}}} = AccountStore.list_balance_history(account)
    end

    test "accepts UUID string for scope arg", %{instance: instance} do
      account = account_fixture(instance_id: instance.id)

      {:ok, {by_struct, _}} = AccountStore.list_balance_history(account)
      {:ok, {by_id, _}} = AccountStore.list_balance_history(account.id)

      assert Enum.map(by_struct, & &1.id) == Enum.map(by_id, & &1.id)
    end
  end
end
