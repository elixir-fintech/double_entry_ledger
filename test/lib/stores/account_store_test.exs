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

  describe "get_accounts" do
    setup [:create_instance]

    test "returns accounts with given ids", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]
      assert {:ok, accounts} == AccountStore.get_accounts(Enum.map(accounts, &(&1.id)))
    end

    test "returns error when some accounts are not found", %{instance: instance} do
      accounts = [
        account_fixture(instance_id: instance.id),
        account_fixture(instance_id: instance.id)
      ]
      account_ids = [instance.id | Enum.map(accounts, &(&1.id))]
      assert {:error, "Some accounts were not found"} == AccountStore.get_accounts(account_ids)
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end
end
