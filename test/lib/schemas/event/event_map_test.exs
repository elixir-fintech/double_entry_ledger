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
      assert %Changeset{
               errors: [
                 transaction_data: {"can't be blank", [validation: :required]},
                 action: {"can't be blank", [validation: :required]},
                 instance_id: {"can't be blank", [validation: :required]},
                 source: {"can't be blank", [validation: :required]},
                 source_idempk: {"can't be blank", [validation: :required]}
               ]
             } = EventMap.changeset(%EventMap{}, %{})
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
      attrs = event_map_attrs()
      assert %Changeset{valid?: true} = EventMap.changeset(%EventMap{}, attrs)
    end

    test "changeset invalid for update action without update_idempk" do
      attrs = event_map_attrs(%{action: "update"})

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = EventMap.changeset(%EventMap{}, attrs)

      attrs2 = event_map_attrs(%{action: :update})

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = EventMap.changeset(%EventMap{}, attrs2)
    end

    test "changeset invalid for update action (key as string) without update_idempk" do
      attrs = %{
        "action" => "update",
        "instance_id" => Ecto.UUID.generate(),
        "source" => "local",
        "source_idempk" => "123",
        "transaction_data" => transaction_data_attrs()
      }

      assert %Changeset{
               errors: [
                 update_idempk: {"can't be blank", [validation: :required]}
               ]
             } = EventMap.changeset(%EventMap{}, attrs)
    end
  end

  def event_map_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      instance_id: Ecto.UUID.generate(),
      action: "create",
      source: "local",
      source_idempk: "123",
      transaction_data: transaction_data_attrs()
    })
  end

  def transaction_data_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      status: "posted",
      entries: [
        %{account_id: Ecto.UUID.generate(), amount: 100, currency: :EUR},
        %{account_id: Ecto.UUID.generate(), amount: 100, currency: :EUR}
      ]
    })
  end
end
