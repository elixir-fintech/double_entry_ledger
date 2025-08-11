defmodule DoubleEntryLedger.MapHelperTest do
  use ExUnit.Case, async: true

  alias DoubleEntryLedger.MapHelper

  describe "deep_atomize_keys!/1" do
    test "returns atoms for top-level string keys" do
      input = %{"a" => 1, "b" => 2}
      assert %{a: 1, b: 2} = MapHelper.deep_atomize_keys!(input)
    end

    test "recursively converts nested maps" do
      input = %{"outer" => %{"inner" => %{"val" => 10}}}
      assert %{outer: %{inner: %{val: 10}}} = MapHelper.deep_atomize_keys!(input)
    end

    test "recursively converts inside lists" do
      input = %{"items" => [%{"k" => 1}, %{"k" => 2}]}
      assert %{items: [%{k: 1}, %{k: 2}]} = MapHelper.deep_atomize_keys!(input)
    end

    test "leaves non-map/list values untouched" do
      assert 5 == MapHelper.deep_atomize_keys!(5)
      assert "str" == MapHelper.deep_atomize_keys!("str")
      assert :ok == MapHelper.deep_atomize_keys!(:ok)
    end

    test "supports already atom keys and mixed keys" do
      input = %{"new" => 2, already: 1}
      assert %{already: 1, new: 2} = MapHelper.deep_atomize_keys!(input)
    end

    test "raises if an unconvertible key type (e.g. integer) appears" do
      bad = %{123 => "x"}
      assert_raise CaseClauseError, fn -> MapHelper.deep_atomize_keys!(bad) end
    end

    test "is idempotent when run twice" do
      input = %{"a" => %{"b" => 1}}
      once = MapHelper.deep_atomize_keys!(input)
      twice = MapHelper.deep_atomize_keys!(once)
      assert once == twice
    end

    test "raises ArgumentError for a string key that isn't an existing atom" do
      dynamic_key = "___unlikely_atom_#{System.unique_integer([:positive])}___"
      assert_raise ArgumentError, fn -> MapHelper.deep_atomize_keys!(%{dynamic_key => 1}) end
    end
  end
end
