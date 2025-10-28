defmodule DoubleEntryLedger.Workers.CommandWorker.CreateAccountEventMapNoSaveOnErrorTest do
  @moduledoc """
    Tests for the CreateAccountEventMapNoSaveOnError
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Account, Command}
  alias DoubleEntryLedger.Stores.InstanceStore
  alias DoubleEntryLedger.Command.{AccountEventMap, AccountData}
  alias DoubleEntryLedger.Workers.CommandWorker.CreateAccountEventMapNoSaveOnError

  import DoubleEntryLedger.InstanceFixtures

  doctest CreateAccountEventMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance]

    test "successfully processes a valid account event map", %{instance: instance} do
      event_map = %AccountEventMap{
        action: :create_account,
        instance_address: instance.address,
        source: "manual",
        payload: %AccountData{
          currency: "USD",
          address: "account:main1",
          name: "Test Account",
          type: "asset"
        }
      }

      {:ok, account, event} = CreateAccountEventMapNoSaveOnError.process(event_map)
      assert account.currency == :USD
      assert account.name == "Test Account"
      assert account.type == :asset
      assert event.command_queue_item.status == :processed
    end

    test "returns an error for an invalid account event map", %{instance: instance} do
      event_map = %AccountEventMap{
        action: :create_account,
        instance_address: instance.address,
        source: "manual",
        payload: %AccountData{
          currency: "USD",
          address: nil,
          type: "asset"
        }
      }

      assert {:error, changeset} = CreateAccountEventMapNoSaveOnError.process(event_map)
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid? == false
      assert Keyword.has_key?(changeset.changes.payload.errors, :address)
    end
  end
end
