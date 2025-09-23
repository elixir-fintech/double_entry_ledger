defmodule DoubleEntryLedger.Event.EntryDataTest do
  @moduledoc """
  Tests for the Entry Data payload
  """
  use ExUnit.Case

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event.EntryData

  doctest EntryData

  describe "Event.EntryData" do
    test "changeset not valid for empty entry data" do
      assert %Changeset{valid?: false} = EntryData.changeset(%EntryData{}, %{})
    end

    test "changeset not valid for missing amount, account_address and type" do
      assert %Changeset{
               errors: [
                 account_address: {"can't be blank", [validation: :required]},
                 amount: {"can't be blank", [validation: :required]},
                 currency: {"can't be blank", [validation: :required]}
               ]
             } = EntryData.changeset(%EntryData{}, %{})
    end

    test "changeset not valid for invalid account_address and currency" do
      attrs = %{
        account_address: Ecto.UUID.generate(),
        amount: 100,
        currency: "invalid"
      }

      assert %Changeset{
               errors: [
                 account_address: {"is not a valid account address", _},
                 currency: {"is invalid", _}
               ]
             } = EntryData.changeset(%EntryData{}, attrs)
    end

    test "changeset valid for valid entry data" do
      attrs = %{
        account_address: "some:address",
        amount: 100,
        currency: :EUR
      }

      assert %Changeset{valid?: true} = EntryData.changeset(%EntryData{}, attrs)
    end
  end
end
