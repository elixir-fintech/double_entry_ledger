defmodule DoubleEntryLedger.EventWorker.CreateAccountEventMapTest do
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event.{AccountEventMap, AccountData}
  alias DoubleEntryLedger.EventWorker.CreateAccountEventMap

  import DoubleEntryLedger.InstanceFixtures

  describe "process/1" do
    setup [:create_instance]

    test "successfully processes a valid account event map", %{instance: instance} do
      event_map = %AccountEventMap{
        action: :create_account,
        instance_id: instance.id,
        source: "manual",
        source_idempk: "acc_123",
        payload: %AccountData{
          currency: "USD",
          name: "Test Account",
          type: "asset"
        }
      }

      {:ok, account, event} = CreateAccountEventMap.process(event_map)
      assert account.currency == :USD
      assert account.name == "Test Account"
      assert account.type == :asset
      assert event.event_queue_item.status == :processed
    end

    test "returns an error for an invalid account event map", %{instance: instance} do
      event_map = %AccountEventMap{
        action: :create_account,
        instance_id: instance.id,
        source: "manual",
        source_idempk: "acc_123",
        payload: %AccountData{
          currency: "USD",
          name: nil,
          type: "asset"
        }
      }

      assert {:error, changeset} = CreateAccountEventMap.process(event_map)
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid? == false
      assert Keyword.has_key?(changeset.errors, :name)
    end
  end
end
