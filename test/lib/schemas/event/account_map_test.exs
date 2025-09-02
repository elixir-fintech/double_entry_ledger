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
                 name: {"can't be blank", [validation: :required]},
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
             } = AccountData.changeset(%AccountData{name: "some_name"}, attrs)
    end

    test "changeset invalid for normal_balance not equal to type" do
      attrs = %{
        name: "some_name",
        type: "asset",
        currency: "EUR",
        normal_balance: "invalid"
      }

      assert %Changeset{errors: [normal_balance: {"is invalid", _}]} = AccountData.changeset(%AccountData{}, attrs)
    end

    test "changeset valid for valid account data" do
      attrs = %{
        name: "some_name",
        type: "asset",
        currency: "EUR"
      }

      assert %Changeset{valid?: true} = AccountData.changeset(%AccountData{}, attrs)
    end
  end
end
