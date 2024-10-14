defmodule DoubleEntryLedger.EventTest do
  @moduledoc """
  Tests for the event
  """
  use ExUnit.Case
  import DoubleEntryLedger.Event.TransactionDataFixtures

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event

  doctest Event

  describe "Event" do
    test "changeset not valid for empty payload" do
      assert %Changeset{errors: [
        transaction_data: {"can't be blank", [validation: :required]},
        action: {"can't be blank", [validation: :required]},
        source: {"can't be blank", [validation: :required]},
        source_id: {"can't be blank", [validation: :required]},
      ]} = Event.changeset(%Event{}, %{})
    end

    test "changeset valid with required attributes and valid payload" do
      attrs = %{
        action: :create,
        source: "source",
        source_id: "source_id",
        transaction_data: pending_payload()
      }
      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
    end
  end
end
