defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommandMapNoSaveOnErrorTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Command.{AccountCommandMap, AccountData}
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommandMapNoSaveOnError
  alias DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommandMapNoSaveOnError

  import DoubleEntryLedger.InstanceFixtures

  doctest UpdateAccountCommandMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance, :create_account]

    test "successfully processes a valid account event map", %{
      instance: instance,
      account: account
    } do
      command_map = %AccountCommandMap{
        action: :update_account,
        instance_address: instance.address,
        account_address: account.address,
        source: "some-source",
        payload: %AccountData{
          description: "Updated Description"
        }
      }

      {:ok, account, event} = UpdateAccountCommandMapNoSaveOnError.process(command_map)
      assert account.description == "Updated Description"
      assert event.command_queue_item.status == :processed
    end
  end

  defp create_account(%{instance: instance} = ctx) do
    command_map = %AccountCommandMap{
      action: :create_account,
      instance_address: instance.address,
      source: "manual",
      payload: %AccountData{
        currency: "USD",
        name: "Test Account",
        address: "account:main#{:rand.uniform(1000)}",
        type: "asset",
        description: "Initial Description"
      }
    }

    {:ok, account, event} = CreateAccountCommandMapNoSaveOnError.process(command_map)

    Map.put(ctx, :account, account)
    |> Map.put(:event, event)
  end
end
