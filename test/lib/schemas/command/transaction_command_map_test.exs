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
