defmodule DoubleEntryLedger.Event.TransactionEventMapTest do
  @moduledoc """
  Tests for the TransactionEventMap payload
  """
  use ExUnit.Case
  alias DoubleEntryLedger.Event.TransactionEventMap
  alias Ecto.Changeset
  doctest TransactionEventMap

  describe "Event.TransactionEventMap" do
    test "changeset not valid for empty data" do
      assert %Changeset{valid?: false} =
               TransactionEventMap.changeset(%TransactionEventMap{}, %{})
    end

    test "changeset not valid for missing action, instance_id, source, source_idempk and transaction_data" do
      %{errors: errors} = TransactionEventMap.changeset(%TransactionEventMap{}, %{})

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
               TransactionEventMap.changeset(%TransactionEventMap{}, attrs)
    end

    test "changeset valid for valid entry data" do
      attrs = event_map_attrs()

      assert %Changeset{valid?: true} =
               TransactionEventMap.changeset(%TransactionEventMap{}, attrs)
    end

    test "changeset invalid for update action without update_idempk" do
      attrs = event_map_attrs(%{action: "update_transaction"})

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = TransactionEventMap.changeset(%TransactionEventMap{}, attrs)

      attrs2 = event_map_attrs(%{action: :update_transaction})

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = TransactionEventMap.changeset(%TransactionEventMap{}, attrs2)
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
             } = TransactionEventMap.changeset(%TransactionEventMap{}, attrs)
    end
  end

  def event_map_attrs(attrs \\ %{}) do
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
