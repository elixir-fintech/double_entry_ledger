defmodule DoubleEntryLedger.Event.TransactionDataTest do
  @moduledoc """
  Tests for the event payload
  """
  use ExUnit.Case
  import DoubleEntryLedger.Event.TransactionDataFixtures

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event.TransactionData

  doctest TransactionData

  describe "changeset/2" do
    test "not valid for empty transaction data" do
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []},
        entries: {"can't be blank", [validation: :required]},
        status: {"can't be blank", [validation: :required]}
      ]} = TransactionData.changeset(%TransactionData{}, %{})
    end

    test "not valid for invalid status" do
      attrs = %{
        status: "invalid",
        entries: create_2_entries()
      }
      assert %Changeset{errors: [
        status: {"is invalid", _}
      ]} = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "not valid for empty entries" do
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

    test "not valid for less than 2 entries" do
      [_ | tail] = create_2_entries()
      attrs = %{
        status: :pending,
        entries: tail
      }
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []}
      ]} = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "valid for valid transaction data" do
      attrs = %{
        status: :pending,
        entries: create_2_entries()
      }
      assert %Changeset{valid?: true} = TransactionData.changeset(%TransactionData{}, attrs)
    end
  end

  describe "update_event_changeset/2" do
    test "not valid for invalid status" do
      attrs = %{
        status: "invalid",
        entries: create_2_entries()
      }
      assert %Changeset{errors: [
        status: {"is invalid", _}
      ]} = TransactionData.update_event_changeset(%TransactionData{}, attrs)
    end

    test "not valid for empty entries" do
      attrs = %{
        status: :pending,
        entries: [%{}]
      }
      assert %Changeset{
        valid?: false,
        changes: %{
          entries: [%Changeset{valid?: false}]
        }
      } = TransactionData.update_event_changeset(%TransactionData{}, attrs)
    end

    test "not valid for less than 2 entries" do
      [_ | tail] = create_2_entries()
      attrs = %{
        status: :pending,
        entries: tail
      }
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []}
      ]} = TransactionData.update_event_changeset(%TransactionData{}, attrs)
    end

    test "valid for simple update to :posted, without entries" do
      attrs = %{
        status: :posted
      }
      assert %Changeset{valid?: true} = TransactionData.update_event_changeset(%TransactionData{}, attrs)
    end

    test "valid for update to :posted with entries" do
      attrs = %{
        status: :posted,
        entries: create_2_entries()
      }
      assert %Changeset{valid?: true} = TransactionData.update_event_changeset(%TransactionData{}, attrs)
    end

    test "valid for simple update to :archived" do
      attrs = %{
        status: :archived,
        entries: []
      }
      %{valid?: true, changes: changes} = TransactionData.update_event_changeset(%TransactionData{}, attrs)
      assert ^changes = %{status: :archived}
    end
  end
end
