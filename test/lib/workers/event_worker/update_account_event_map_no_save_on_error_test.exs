defmodule DoubleEntryLedger.EventWorker.UpdateAccountEventMapNoSaveOnErrorTest do
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Event.{AccountEventMap, AccountData}
  alias DoubleEntryLedger.EventWorker.UpdateAccountEventMapNoSaveOnError
  alias DoubleEntryLedger.EventWorker.CreateAccountEventMapNoSaveOnError

  import DoubleEntryLedger.InstanceFixtures

  doctest UpdateAccountEventMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance, :create_account]

    test "successfully processes a valid account event map", %{instance: instance, event: event} do
      event_map = %AccountEventMap{
        action: :update_account,
        instance_address: instance.address,
        source: event.source,
        source_idempk: event.source_idempk,
        update_idempk: "update_456",
        payload: %AccountData{
          description: "Updated Description"
        }
      }

      {:ok, account, event} = UpdateAccountEventMapNoSaveOnError.process(event_map)
      assert account.description == "Updated Description"
      assert event.event_queue_item.status == :processed
    end

    test "returns an error for an invalid account event map", %{instance: instance, event: event} do
      event_map = %AccountEventMap{
        action: :update_account,
        instance_address: instance.address,
        source: event.source,
        source_idempk: event.source_idempk,
        payload: %AccountData{
          description: "Updated Description"
        }
      }

      assert {:error, changeset} = UpdateAccountEventMapNoSaveOnError.process(event_map)
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid? == false
      assert Keyword.has_key?(changeset.errors, :update_idempk)
    end
  end

  defp create_account(%{instance: instance} = ctx) do
    event_map = %AccountEventMap{
      action: :create_account,
      instance_address: instance.address,
      source: "manual",
      source_idempk: "acc_123",
      payload: %AccountData{
        currency: "USD",
        name: "Test Account",
        address: "account:main#{:rand.uniform(1000)}",
        type: "asset",
        description: "Initial Description"
      }
    }

    {:ok, account, event} = CreateAccountEventMapNoSaveOnError.process(event_map)

    Map.put(ctx, :account, account)
    |> Map.put(:event, event)
  end
end
