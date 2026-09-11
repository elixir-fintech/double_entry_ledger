defmodule DoubleEntryLedger.BatchSerializerTest do
  @moduledoc """
  Pure unit tests for `DoubleEntryLedger.BatchSerializer`.

  No DB. Each test is linear (no `if`/`case`/`cond`/recursion in test
  code).
  """

  use ExUnit.Case, async: true

  alias DoubleEntryLedger.{Balance, BatchSerializer}

  describe "dump_balance/1" do
    test "produces a plain map of amount/debit/credit" do
      balance = %Balance{amount: 100, debit: 100, credit: 0}

      assert BatchSerializer.dump_balance(balance) ==
               %{amount: 100, debit: 100, credit: 0}
    end

    test "result has no __struct__ key" do
      balance = %Balance{amount: 0, debit: 0, credit: 0}

      refute Map.has_key?(BatchSerializer.dump_balance(balance), :__struct__)
    end

    test "matches Map.from_struct/1 — the canonical embed-dump shape" do
      balance = %Balance{amount: 42, debit: 50, credit: 8}

      assert BatchSerializer.dump_balance(balance) == Map.from_struct(balance)
    end
  end

  describe "dump_money/1" do
    test "produces a plain map with string keys for amount and currency" do
      money = Money.new(100, :USD)

      assert BatchSerializer.dump_money(money) ==
               %{"amount" => 100, "currency" => "USD"}
    end

    test "matches Money.Ecto.Map.Type.dump/1 (unwrapped) — byte-equivalent to legacy path" do
      money = Money.new(2_500, :EUR)

      {:ok, ecto_dumped} = Money.Ecto.Map.Type.dump(money)

      assert BatchSerializer.dump_money(money) == ecto_dumped
    end
  end
end
