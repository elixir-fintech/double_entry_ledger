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
      changeset = TransactionData.changeset(%TransactionData{}, %{})
      assert {"must have at least 2 entries", []} = Keyword.get(changeset.errors, :entry_count)
      assert {"can't be blank", [validation: :required]} = Keyword.get(changeset.errors, :entries)
      assert {"can't be blank", [validation: :required]} = Keyword.get(changeset.errors, :status)
    end

    test "not valid for invalid status" do
      attrs = %{
        status: "invalid",
        entries: create_2_entries()
      }
      assert {"is invalid", _} = Keyword.get(TransactionData.changeset(%TransactionData{}, attrs).errors, :status)
    end

    test "not valid for empty entries" do
      attrs = %{
        status: :pending,
        entries: [%{}]
      }
      TransactionData.changeset(%TransactionData{}, attrs)
      |> get_embed(:entries, :changeset)
      |> Enum.map(& assert &1.valid? == false)
      |> then(& assert length(&1) == 1)
    end

    test "not valid for less than 2 entries" do
      [_ | tail] = create_2_entries()
      attrs = %{
        status: :pending,
        entries: tail
      }
      changeset = TransactionData.changeset(%TransactionData{}, attrs)
      assert {"must have at least 2 entries", []} = Keyword.get(changeset.errors, :entry_count)
    end

    test "adds error to single entry" do
      [_ | tail] = create_2_entries()
      attrs = %{
        status: :pending,
        entries: tail
      }
      TransactionData.changeset(%TransactionData{}, attrs)
      |> get_embed(:entries, :changeset)
      |> Enum.map(& assert {"at least 2 accounts are required", []} = &1.errors[:account_id])
      |> then(& assert length(&1) == 1)
    end

    test "not valid for 2 entries with same account" do
      id = Ecto.UUID.generate()
      attr = %{
        status: :pending,
        entries: [
          %{account_id: id, amount: 100, currency: :EUR},
          %{account_id: id, amount: -100, currency: :EUR}
        ]
      }
      TransactionData.changeset(%TransactionData{}, attr)
      |> get_embed(:entries, :changeset)
      |> Enum.map(& assert {"account IDs must be distinct", []} = &1.errors[:account_id])
      |> then(& assert length(&1) == 2)
    end

    test "valid for valid transaction data" do
      attrs = %{
        status: :pending,
        entries: create_2_entries()
      }
      assert TransactionData.changeset(%TransactionData{}, attrs).valid?
    end
  end

  describe "update_event_changeset/2" do
    test "not valid for invalid status" do
      attrs = %{
        status: "invalid",
        entries: create_2_entries()
      }
      assert {"is invalid", _} =
        Keyword.get(TransactionData.changeset(%TransactionData{}, attrs).errors, :status)
    end

    test "not valid for empty entries" do
      attrs = %{
        status: :pending,
        entries: [%{}]
      }
      TransactionData.update_event_changeset(%TransactionData{}, attrs)
      |> get_embed(:entries, :changeset)
      |> Enum.map(& assert &1.valid? == false)
      |> then(& assert length(&1) == 1)
    end

    test "not valid for less than 2 entries" do
      [_ | tail] = create_2_entries()
      attrs = %{
        status: :pending,
        entries: tail
      }
      assert {"must have at least 2 entries", []} =
        Keyword.get(TransactionData.changeset(%TransactionData{}, attrs).errors, :entry_count)
    end

    test "valid for simple update to :posted, without entries" do
      attrs = %{
        status: :posted
      }
      assert TransactionData.update_event_changeset(%TransactionData{}, attrs).valid?
    end

    test "valid for update to :posted with entries" do
      attrs = %{
        status: :posted,
        entries: create_2_entries()
      }
      assert TransactionData.update_event_changeset(%TransactionData{}, attrs).valid?
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
