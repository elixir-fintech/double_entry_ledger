defmodule DoubleEntryLedger.Event.TransactionDataTest do
  @moduledoc """
  Tests for the event payload
  """
  use ExUnit.Case
  import DoubleEntryLedger.Event.TransactionDataFixtures

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event.TransactionData

  describe "Event.TransactionData" do
    test "changeset not valid for empty transaction data" do
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []},
        entries: {"can't be blank", [validation: :required]},
        status: {"can't be blank", [validation: :required]}
      ]} = TransactionData.changeset(%TransactionData{}, %{})
    end

    test "changeset not valid for invalid status and datetime" do
      attrs = %{
        status: "invalid",
        entries: create_2_entries()
      }
      assert %Changeset{errors: [
        status: {"is invalid", _}
      ]} = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "changeset not valid for empty entries" do
      attrs = %{
        status: :pending,
        entries: [%{}]
      }
      assert %Changeset{
        valid?: false,
        changes: %{
          entries: [%Changeset{valid?: false}]
        }
      } = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "changeset not valid for less than 2 entries" do
      [_ | tail] = create_2_entries()
      attrs = %{
        status: :pending,
        entries: tail
      }
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []}
      ]} = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "changeset valid for valid transaction data" do
      attrs = %{
        status: :pending,
        entries: create_2_entries()
      }
      assert %Changeset{valid?: true} = TransactionData.changeset(%TransactionData{}, attrs)
    end
  end
end
