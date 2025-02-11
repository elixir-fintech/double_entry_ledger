defmodule DoubleEntryLedger.Event.EventMapTest do
  @moduledoc """
  Tests for the EventMap payload
  """
  use ExUnit.Case
  alias DoubleEntryLedger.Event.EventMap
  alias Ecto.Changeset
  doctest EventMap

  describe "Event.EventMap" do
    test "changeset not valid for empty data" do
      assert %Changeset{valid?: false} = EventMap.changeset(%EventMap{}, %{})
    end

    test "changeset not valid for missing action, instance_id, source, source_idempk and transaction_data" do
      assert %Changeset{errors: [
        transaction_data: {"can't be blank", [validation: :required]},
        action: {"can't be blank", [validation: :required]},
        instance_id: {"can't be blank", [validation: :required]},
        source: {"can't be blank", [validation: :required]},
        source_idempk: {"can't be blank", [validation: :required]},
      ]} = EventMap.changeset(%EventMap{}, %{})
    end

    test "changeset invalid for empty transaction_data struct" do
      attrs = %{
        instance_id: Ecto.UUID.generate(),
        action: "create",
        source: "local",
        source_idempk: "123",
        transaction_data: %{}
      }
      assert %Changeset{valid?: false} = EventMap.changeset(%EventMap{}, attrs)
    end

    test "changeset valid for valid entry data" do
      attrs = %{
        instance_id: Ecto.UUID.generate(),
        action: "create",
        source: "local",
        source_idempk: "123",
        transaction_data: %{
          status: "posted",
          entries: [
            %{account_id: Ecto.UUID.generate(), amount: 100, currency: :EUR},
            %{account_id: Ecto.UUID.generate(), amount: 100, currency: :EUR}
          ]
        }
      }
      assert %Changeset{valid?: true} = EventMap.changeset(%EventMap{}, attrs)
    end
  end
end
