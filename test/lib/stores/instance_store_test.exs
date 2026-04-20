defmodule DoubleEntryLedger.Stores.InstanceStoreTest do
  @moduledoc """
  This module tests the InstanceStore behaviour.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.TransactionFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.Stores.InstanceStore

  doctest InstanceStore

  describe "sum_accounts_debits_and_credits_by_currency" do
    setup [:create_instance]

    test "it works for empty accounts", %{instance: inst} do
      assert {
               :ok,
               []
             } = InstanceStore.sum_accounts_debits_and_credits_by_currency(inst.id)
    end

    test "it works for balanced accounts", %{instance: inst} = ctx do
      new_ctx = create_accounts(ctx)
      create_transaction(new_ctx)
      create_transaction(new_ctx, :posted)

      assert {
               :ok,
               [
                 %{
                   currency: :EUR,
                   pending_credit: 100,
                   pending_debit: 100,
                   posted_credit: 100,
                   posted_debit: 100
                 }
               ]
             } = InstanceStore.sum_accounts_debits_and_credits_by_currency(inst.id)
    end
  end

  describe "list/1" do
    test "returns first page with all rows when under default limit" do
      for i <- 1..3, do: {:ok, _} = InstanceStore.create(%{address: "tenant:#{i}"})

      assert {:ok, {instances, %Flop.Meta{} = meta}} = InstanceStore.list()
      assert length(instances) == 3
      assert meta.has_next_page? == false
    end

    test "paginates with first/after cursor" do
      for i <- 1..5, do: {:ok, _} = InstanceStore.create(%{address: "tenant:#{i}"})

      {:ok, {page_1, meta_1}} = InstanceStore.list(%{first: 2})
      assert length(page_1) == 2
      assert meta_1.has_next_page? == true

      {:ok, {page_2, _meta_2}} = InstanceStore.list(%{first: 2, after: meta_1.end_cursor})
      assert length(page_2) == 2
      page_1_ids = Enum.map(page_1, & &1.id)
      page_2_ids = Enum.map(page_2, & &1.id)
      assert page_1_ids -- page_2_ids == page_1_ids
    end

    test "filters by address (allow-listed)" do
      {:ok, %{id: match_id}} = InstanceStore.create(%{address: "tenant:match"})
      {:ok, _} = InstanceStore.create(%{address: "tenant:other"})

      assert {:ok, {[%{id: ^match_id}], _meta}} =
               InstanceStore.list(%{
                 filters: [%{field: :address, op: :==, value: "tenant:match"}]
               })
    end

    test "rejects filtering by non-allow-listed field" do
      assert {:error, %Flop.Meta{errors: errors}} =
               InstanceStore.list(%{filters: [%{field: :description, op: :==, value: "x"}]})

      refute errors == []
    end
  end
end
