defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommandTest do
  @moduledoc """
  Tests for CreateAccountCommand
  """

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Command, Account, Repo, CommandQueueItem}
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.{CreateAccountCommand, UpdateAccountCommand}
  alias DoubleEntryLedger.Command.AccountData

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.Command.AccountDataFixtures

  doctest UpdateAccountCommand

  describe "process/1" do
    setup [:create_instance]

    test "successfully processes a valid update account event", %{instance: instance} do
      attrs =
        account_event_attrs(%{
          instance_address: instance.address,
          payload: account_data_attrs(%{name: "Old Name"})
        })

      {:ok, %{event_map: %{payload: payload}} = create_event} = CommandStore.create(attrs)

      CreateAccountCommand.process(create_event)

      update_attrs =
        account_event_attrs(%{
          action: :update_account,
          instance_address: instance.address,
          account_address: payload.address,
          source: "some-source",
          payload: %AccountData{name: "New Name"}
        })

      {:ok, update_event} = CommandStore.create(update_attrs)

      assert {:ok, %Account{} = account, %Command{command_queue_item: eqi} = e} =
               UpdateAccountCommand.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :processed
      assert account.address == "account:1"
      assert account.name == "New Name"
    end

    test "moves to dead_letter when create account event does not exist", %{instance: instance} do
      {:ok, update_event} =
        CommandStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            account_address: "non:existent",
            source: "src",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:error, %Command{command_queue_item: eqi} = e} =
               UpdateAccountCommand.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :dead_letter
    end

    test "goes to dead letter when create account event is not yet processed", %{
      instance: instance
    } do
      {:ok, %{event_map: %{payload: payload}}} =
        CommandStore.create(
          account_event_attrs(%{
            instance_address: instance.address,
            payload: account_data_attrs(%{name: "Old Name"})
          })
        )

      {:ok, update_event} =
        CommandStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            account_address: payload.address,
            source: "source",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:error, %Command{command_queue_item: eqi} = e} =
               UpdateAccountCommand.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :dead_letter
    end

    test "moves to dead letter when create event is in dead letter", %{instance: instance} do
      {:ok, %{event_map: %{payload: create_payload}, command_queue_item: event_qi}} =
        CommandStore.create(
          account_event_attrs(%{
            instance_address: instance.address,
            payload: %AccountData{address: "sss", type: :asset, currency: :EUR}
          })
        )

      from(eqi in CommandQueueItem, where: eqi.id == ^event_qi.id)
      |> Repo.update_all(set: [status: :dead_letter])

      {:ok, update_event} =
        CommandStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            account_address: create_payload.address,
            source: "src",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:error, %Command{command_queue_item: eqi} = e} =
               UpdateAccountCommand.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :dead_letter
    end
  end
end
