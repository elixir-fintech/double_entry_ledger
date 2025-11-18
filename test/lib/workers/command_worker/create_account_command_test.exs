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
  import DoubleEntryLedger.EventFixtures

  doctest CreateAccountCommand

  describe "process/1" do
    setup [:create_instance]

    test "successfully processes a valid create_account event", %{instance: instance} do
      {:ok, event} =
        CommandStore.create(account_event_attrs(%{instance_address: instance.address}))

      assert {:ok, %Account{} = account, %Command{command_queue_item: eqi} = e} =
               CreateAccountCommand.process(preload(event))

      assert e.id == event.id
      assert eqi.status == :processed
      assert account.address == "account:1"
    end

    test "fails when there is an account issue", %{instance: instance} do
      address = "same:address"

      {:ok, event1} =
        CommandStore.create(
          account_event_attrs(%{address: address, instance_address: instance.address})
        )

      {:ok, event2} =
        CommandStore.create(
          account_event_attrs(%{address: address, instance_address: instance.address})
        )

      CreateAccountCommand.process(preload(event1))

      assert {:error, %Command{command_queue_item: %{errors: errors} = eqi}} =
               CreateAccountCommand.process(preload(event2))

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

    defp preload(event) do
      Repo.reload(event)
      |> Repo.preload(:command_queue_item)
    end
  end
end
