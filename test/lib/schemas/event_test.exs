defmodule DoubleEntryLedger.EventTest do
  @moduledoc """
  Tests for the event
  """
  use ExUnit.Case
  import DoubleEntryLedger.EventPayloadFixtures

  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event

  doctest Event

  describe "Event" do
    test "changeset not valid for empty payload" do
      assert %Changeset{errors: [
        payload: {"can't be blank", [validation: :required]},
        event_type: {"can't be blank", [validation: :required]},
        source: {"can't be blank", [validation: :required]},
        source_id: {"can't be blank", [validation: :required]},
      ]} = Event.changeset(%Event{}, %{})
    end

    test "changeset valid with required attributes and valid payload" do
      attrs = %{
        event_type: :create,
        source: "source",
        source_id: "source_id",
        payload: pending_payload()
      }
      assert %Changeset{valid?: true} = Event.changeset(%Event{}, attrs)
    end
  end
end
