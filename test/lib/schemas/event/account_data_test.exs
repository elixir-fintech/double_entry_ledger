defmodule DoubleEntryLedger.Event.AccountDataTest do
  @moduledoc """
  Tests for AccountData payload
  """
  use ExUnit.Case

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event.AccountData

  doctest AccountData

  describe "Event.AccountData" do
    test "changeset not valid for empty account data" do
      assert %Changeset{valid?: false} = AccountData.changeset(%AccountData{}, %{})
    end

    test "changeset not valid for name, currency and type" do
      assert %Changeset{
               errors: [
                 currency: {"can't be blank", [validation: :required]},
                 address: {"can't be blank", [validation: :required]},
                 type: {"can't be blank", [validation: :required]}
               ]
             } = AccountData.changeset(%AccountData{}, %{})
    end

    test "changeset not valid for invalid currency" do
      attrs = %{
        type: "invalid",
        currency: "invalid"
      }

      assert %Changeset{
               errors: [
                 currency: {"is invalid", _},
                 type: {"is invalid", _}
               ]
             } =
               AccountData.changeset(
                 %AccountData{name: "some_name", address: "some:address"},
                 attrs
               )
    end

    test "changeset invalid for normal_balance not equal to type" do
      attrs = %{
        name: "some_name",
        address: "some:address",
        type: "asset",
        currency: "EUR",
        normal_balance: "invalid"
      }

      assert %Changeset{errors: [normal_balance: {"is invalid", _}]} =
               AccountData.changeset(%AccountData{}, attrs)
    end

    test "changeset invalid for wrong formatted address" do
      attrs = %{
        name: "some_name",
        address: "some address",
        type: "asset",
        currency: "EUR"
      }

      assert %Changeset{errors: [address: {"has invalid format", [validation: :format]}]} =
               AccountData.changeset(%AccountData{}, attrs)
    end

    test "changeset valid for valid account data" do
      attrs = %{
        name: "some_name",
        address: "some:address",
        type: "asset",
        currency: "EUR"
      }

      assert %Changeset{valid?: true} = AccountData.changeset(%AccountData{}, attrs)
    end
  end

  describe "to_map/1" do
    test "converts account data to map" do
      account_data = %AccountData{
        currency: :EUR,
        name: "some_name",
        description: "some_description",
        context: %{"key" => "value"},
        normal_balance: :debit,
        type: :asset,
        allowed_negative: false
      }

      expected_map = %{
        currency: :EUR,
        name: "some_name",
        description: "some_description",
        context: %{"key" => "value"},
        normal_balance: :debit,
        type: :asset,
        allowed_negative: false
      }

      assert AccountData.to_map(account_data) == expected_map
    end

    test "converts account data with nil fields to map" do
      account_data = %AccountData{
        currency: :USD,
        name: "another_name",
        description: nil,
        context: nil,
        normal_balance: nil,
        type: :liability,
        allowed_negative: true
      }

      expected_map = %{
        currency: :USD,
        name: "another_name",
        type: :liability,
        allowed_negative: true
      }

      assert AccountData.to_map(account_data) == expected_map
    end
  end
end
