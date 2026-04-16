defmodule DoubleEntryLedger.Command.TransactionCommandMapTest do
  @moduledoc """
  Tests for the TransactionCommandMap payload
  """
  use ExUnit.Case
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias Ecto.Changeset
  doctest TransactionCommandMap

  describe "Command.TransactionCommandMap" do
    test "changeset not valid for empty data" do
      assert %Changeset{valid?: false} =
               TransactionCommandMap.changeset(%TransactionCommandMap{}, %{})
    end

    test "changeset not valid for missing action, instance_id, source, source_idempk and transaction_data" do
      %{errors: errors} = TransactionCommandMap.changeset(%TransactionCommandMap{}, %{})

      assert Keyword.equal?(errors,
               payload: {"can't be blank", [validation: :required]},
               action: {"can't be blank", [validation: :required]},
               action: {"invalid in this context", [value: ""]},
               instance_address: {"can't be blank", [validation: :required]},
               source: {"can't be blank", [validation: :required]},
               source_idempk: {"can't be blank", [validation: :required]}
             )
    end

    test "changeset invalid for empty transaction_data struct" do
      attrs = %{
        instance_address: "some:address",
        action: "create_transaction",
        source: "local",
        source_idempk: "123",
        payload: %{}
      }

      assert %Changeset{valid?: false} =
               TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
    end

    test "changeset valid for valid entry data" do
      attrs = command_map_attrs()

      assert %Changeset{valid?: true} =
               TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
    end

    test "changeset invalid for update action without update_idempk" do
      attrs = command_map_attrs(%{action: "update_transaction"})

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)

      attrs2 = command_map_attrs(%{action: :update_transaction})

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs2)
    end

    test "changeset invalid for update action (key as string) without update_idempk" do
      attrs = %{
        "action" => "update_transaction",
        "instance_address" => "some:address",
        "source" => "local",
        "source_idempk" => "123",
        "payload" => transaction_data_attrs()
      }

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
    end
  end

  describe "trace_context" do
    test "changeset accepts optional trace_context map" do
      attrs =
        command_map_attrs(%{
          trace_context: %{"traceparent" => "00-abc123", "tracestate" => "vendor=xyz"}
        })

      changeset = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
      assert changeset.valid?

      assert Changeset.get_field(changeset, :trace_context) == %{
               "traceparent" => "00-abc123",
               "tracestate" => "vendor=xyz"
             }
    end

    test "changeset rejects trace_context with more than 10 keys" do
      large_context =
        0..10
        |> Enum.map(fn i -> {"key_#{i}", "value_#{i}"} end)
        |> Map.new()

      attrs = command_map_attrs(%{trace_context: large_context})

      changeset = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
      refute changeset.valid?
      assert {"must have at most 10 keys", _} = changeset.errors[:trace_context]
    end

    test "changeset rejects trace_context with nested maps" do
      attrs = command_map_attrs(%{trace_context: %{"parent" => %{"nested" => "value"}}})

      changeset = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
      refute changeset.valid?
      assert {"values must be strings", _} = changeset.errors[:trace_context]
    end

    test "changeset valid without trace_context" do
      attrs = command_map_attrs()

      changeset = TransactionCommandMap.changeset(%TransactionCommandMap{}, attrs)
      assert changeset.valid?
      assert Changeset.get_field(changeset, :trace_context) == nil
    end

    test "trace_context included in to_map when present" do
      {:ok, command_map} =
        TransactionCommandMap.create(
          command_map_attrs(%{
            trace_context: %{"traceparent" => "00-abc123"}
          })
        )

      map = TransactionCommandMap.to_map(command_map)
      assert map.trace_context == %{"traceparent" => "00-abc123"}
    end

    test "trace_context excluded from to_map when nil" do
      {:ok, command_map} = TransactionCommandMap.create(command_map_attrs())

      map = TransactionCommandMap.to_map(command_map)
      refute Map.has_key?(map, :trace_context)
    end
  end

  def command_map_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      instance_address: "some:address",
      action: "create_transaction",
      source: "local",
      source_idempk: "123",
      payload: transaction_data_attrs()
    })
  end

  def transaction_data_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      status: "posted",
      entries: [
        %{account_address: "cash:account", amount: 100, currency: :EUR},
        %{account_address: "loan:account", amount: 100, currency: :EUR}
      ]
    })
  end
end
