defmodule DoubleEntryLedger.Command.AccountCommandMapTest do
  use ExUnit.Case, async: true

  alias DoubleEntryLedger.Command.AccountCommandMap
  alias Ecto.Changeset

  doctest AccountCommandMap

  describe "trace_context" do
    test "changeset accepts optional trace_context map" do
      attrs =
        account_command_map_attrs(%{
          trace_context: %{"traceparent" => "00-abc123"}
        })

      changeset = AccountCommandMap.changeset(%AccountCommandMap{}, attrs)
      assert changeset.valid?
      assert Changeset.get_field(changeset, :trace_context) == %{"traceparent" => "00-abc123"}
    end

    test "changeset rejects trace_context with more than 10 keys" do
      large_context =
        0..10
        |> Enum.map(fn i -> {"key_#{i}", "value_#{i}"} end)
        |> Map.new()

      attrs = account_command_map_attrs(%{trace_context: large_context})

      changeset = AccountCommandMap.changeset(%AccountCommandMap{}, attrs)
      refute changeset.valid?
      assert {"must have at most 10 keys", _} = changeset.errors[:trace_context]
    end

    test "changeset rejects trace_context with nested maps" do
      attrs =
        account_command_map_attrs(%{trace_context: %{"parent" => %{"nested" => "value"}}})

      changeset = AccountCommandMap.changeset(%AccountCommandMap{}, attrs)
      refute changeset.valid?
      assert {"values must be strings", _} = changeset.errors[:trace_context]
    end

    test "changeset valid without trace_context" do
      attrs = account_command_map_attrs()

      changeset = AccountCommandMap.changeset(%AccountCommandMap{}, attrs)
      assert changeset.valid?
      assert Changeset.get_field(changeset, :trace_context) == nil
    end

    test "trace_context included in to_map when present" do
      {:ok, command_map} =
        AccountCommandMap.create(
          account_command_map_attrs(%{
            trace_context: %{"traceparent" => "00-abc123"}
          })
        )

      map = AccountCommandMap.to_map(command_map)
      assert map.trace_context == %{"traceparent" => "00-abc123"}
    end

    test "trace_context excluded from to_map when nil" do
      {:ok, command_map} = AccountCommandMap.create(account_command_map_attrs())

      map = AccountCommandMap.to_map(command_map)
      refute Map.has_key?(map, :trace_context)
    end
  end

  defp account_command_map_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create_account,
      instance_address: "Test:Ledger",
      source: "test",
      payload: %{
        name: "Test Account",
        address: "account:main",
        type: :asset,
        currency: "USD"
      }
    })
  end
end
