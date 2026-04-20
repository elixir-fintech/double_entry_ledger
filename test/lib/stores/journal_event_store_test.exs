defmodule DoubleEntryLedger.Stores.JournalEventStoreTest do
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Stores.{
    AccountStore,
    InstanceStore,
    JournalEventStore,
    JournalEventStoreHelper,
    TransactionStore
  }

  doctest JournalEventStoreHelper
  doctest JournalEventStore

  defp post_transaction(inst, a1, a2, idem) do
    attrs = %{
      status: :posted,
      entries: [
        %{account_address: a1.address, amount: 100, currency: :EUR},
        %{account_address: a2.address, amount: 100, currency: :EUR}
      ]
    }

    {:ok, _} = TransactionStore.create(inst.address, attrs, idem)
    :ok
  end

  describe "list_for_instance/2" do
    setup [:create_instance, :create_accounts]

    test "returns journal events for the instance", %{instance: inst, accounts: [a1, a2 | _]} do
      :ok = post_transaction(inst, a1, a2, "idem-je-1")

      assert {:ok, {events, %Flop.Meta{}}} = JournalEventStore.list_for_instance(inst)
      assert length(events) == 1
      assert hd(events).command_map.action == :create_transaction
    end

    test "accepts UUID string for scope arg", %{instance: inst, accounts: [a1, a2 | _]} do
      :ok = post_transaction(inst, a1, a2, "idem-je-2")

      {:ok, {by_struct, _}} = JournalEventStore.list_for_instance(inst)
      {:ok, {by_id, _}} = JournalEventStore.list_for_instance(inst.id)

      assert length(by_struct) == length(by_id)
    end
  end

  describe "list_for_account/2 and list_for_account_address/3" do
    setup [:create_instance, :create_accounts]

    test "list_for_account returns events for the account", %{instance: inst, accounts: [a1, a2 | _]} do
      :ok = post_transaction(inst, a1, a2, "idem-je-acc")

      assert {:ok, {events, %Flop.Meta{}}} = JournalEventStore.list_for_account(a1)
      assert length(events) == 1
      assert hd(events).command_map.action == :create_transaction
    end

    test "list_for_account accepts UUID string for scope arg", %{instance: inst, accounts: [a1, a2 | _]} do
      :ok = post_transaction(inst, a1, a2, "idem-je-acc-u")

      {:ok, {by_struct, _}} = JournalEventStore.list_for_account(a1)
      {:ok, {by_id, _}} = JournalEventStore.list_for_account(a1.id)

      assert length(by_struct) == 1
      assert Enum.map(by_struct, & &1.id) == Enum.map(by_id, & &1.id)
    end

    test "list_for_account_address returns events for (instance_addr, account_addr)", %{
      instance: inst,
      accounts: [a1, a2 | _]
    } do
      :ok = post_transaction(inst, a1, a2, "idem-je-addr")

      assert {:ok, {events, %Flop.Meta{}}} =
               JournalEventStore.list_for_account_address(inst.address, a1.address)

      assert length(events) == 1
      assert hd(events).command_map.action == :create_transaction
    end

    test "list_for_account_address returns empty page for unknown address", %{instance: inst} do
      assert {:ok, {[], %Flop.Meta{}}} =
               JournalEventStore.list_for_account_address(inst.address, "no:such:account")
    end
  end
end
