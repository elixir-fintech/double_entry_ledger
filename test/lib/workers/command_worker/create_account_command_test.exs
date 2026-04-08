defmodule DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommandTest do
  @moduledoc """
  Tests for CreateAccountCommand
  """

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Command, Account}
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommand

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.CommandFixtures

  doctest CreateAccountCommand

  describe "process/1" do
    setup [:create_instance]

    test "successfully processes a valid create_account command", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(account_command_attrs(%{instance_address: instance.address}))

      assert {:ok, %Account{} = account, %Command{command_queue_item: eqi} = e} =
               CreateAccountCommand.process(preload(command))

      assert e.id == command.id
      assert eqi.status == :processed
      assert account.address == "account:1"
    end

    test "fails when there is an account issue", %{instance: instance} do
      address = "same:address"

      {:ok, command1} =
        CommandStore.create(
          account_command_attrs(%{address: address, instance_address: instance.address})
        )

      {:ok, command2} =
        CommandStore.create(
          account_command_attrs(%{address: address, instance_address: instance.address})
        )

      CreateAccountCommand.process(preload(command1))

      assert {:error, %Command{command_queue_item: %{errors: errors} = eqi}} =
               CreateAccountCommand.process(preload(command2))

      assert eqi.status == :dead_letter

      assert [
               %{
                 message:
                   "AccountCommandResponseHandler: Account changeset failed: %{address: [\"has already been taken\"]}"
               }
               | _
             ] =
               errors
    end

    defp preload(command) do
      Repo.reload(command)
      |> Repo.preload(:command_queue_item)
    end
  end
end
