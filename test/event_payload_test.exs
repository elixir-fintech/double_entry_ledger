defmodule DoubleEntryLedger.EventPayloadTest do
  @moduledoc """
  Tests for the event payload
  """
  use ExUnit.Case
  import DoubleEntryLedger.EventPayloadFixtures

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.EventPayload
  alias DoubleEntryLedger.EventPayload.{TransactionData, EntryData}

  doctest EventPayload

  describe "EventPayload" do
    test "changeset not valid for empty transaction and instance_id" do
      assert %Changeset{errors: [
        transaction: {"can't be blank", [validation: :required]},
        instance_id: {"can't be blank", [validation: :required]}
      ]} = EventPayload.changeset(%EventPayload{}, %{})
    end

    test "changeset not valid if instance_id is not a UUID" do
      attrs = %{instance_id: "some_id", transaction: %{}}
      assert %Changeset{errors: [
        instance_id: {"is invalid", [type: Ecto.UUID, validation: :cast]}
      ]} = EventPayload.changeset(%EventPayload{}, attrs)
    end

    test "changeset not valid for empty transaction because of invalid transaction changeset" do
      attrs = %{
        instance_id: Ecto.UUID.generate(),
        transaction: %{}
      }
      assert %Changeset{
        valid?: false,
        changes: %{
          transaction: %Changeset{valid?: false}
        }
      } = EventPayload.changeset(%EventPayload{}, attrs)
    end

    test "changeset valid for valid payload" do
      attrs = pending_payload()
      assert %Changeset{valid?: true} = EventPayload.changeset(%EventPayload{}, attrs)
    end
  end

  describe "EventPayload.TransactionData" do
    test "changeset not valid for empty transaction data" do
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []},
        entries: {"can't be blank", [validation: :required]},
        effective_at: {"can't be blank", [validation: :required]},
        status: {"can't be blank", [validation: :required]}
      ]} = TransactionData.changeset(%TransactionData{}, %{})
    end

    test "changeset not valid for invalid status and datetime" do
      attrs = %{
        effective_at: "some_date",
        status: "invalid",
        entries: create_2_entries()
      }
      assert %Changeset{errors: [
        effective_at: {"is invalid", _},
        status: {"is invalid", _}
      ]} = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "changeset not valid for empty entries" do
      attrs = %{
        effective_at: DateTime.utc_now(),
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
        effective_at: DateTime.utc_now(),
        status: :pending,
        entries: tail
      }
      assert %Changeset{errors: [
        entries: {"must have at least 2 entries", []}
      ]} = TransactionData.changeset(%TransactionData{}, attrs)
    end

    test "changeset valid for valid transaction data" do
      attrs = %{
        effective_at: DateTime.utc_now(),
        status: :pending,
        entries: create_2_entries()
      }
      assert %Changeset{valid?: true} = TransactionData.changeset(%TransactionData{}, attrs)
    end
  end

  describe "EventPayload.EntryData" do
    test "changeset not valid for empty entry data" do
      assert %Changeset{valid?: false} = EntryData.changeset(%EntryData{}, %{})
    end

    test "changeset not valid for missing amount, account_id and type" do
      assert %Changeset{errors: [
        account_id: {"can't be blank", [validation: :required]},
        amount: {"can't be blank", [validation: :required]},
        currency: {"can't be blank", [validation: :required]}
      ]} = EntryData.changeset(%EntryData{}, %{})
    end

    test "changeset not valid for invalid account_id and currency" do
      attrs = %{
        account_id: "some_id",
        amount: 100,
        currency: "invalid"
      }
      assert %Changeset{errors: [
        account_id: {"is invalid", _},
        currency: {"is invalid", _}
      ]} = EntryData.changeset(%EntryData{}, attrs)
    end

    test "changeset valid for valid entry data" do
      attrs = %{
        account_id: Ecto.UUID.generate(),
        amount: 100,
        currency: :EUR
      }
      assert %Changeset{valid?: true} = EntryData.changeset(%EntryData{}, attrs)
    end
  end
end
