defmodule DoubleEntryLedger.Workers.EventWorker.UpdateAccountEventTest do
  @moduledoc """
  Tests for CreateAccountEvent
  """

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Event, Account, Repo, EventQueueItem}
  alias DoubleEntryLedger.Stores.EventStore
  alias DoubleEntryLedger.Workers.EventWorker.{CreateAccountEvent, UpdateAccountEvent}
  alias DoubleEntryLedger.Event.AccountData

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.Event.AccountDataFixtures

  doctest UpdateAccountEvent

  describe "process/1" do
    setup [:create_instance]

    test "successfully processes a valid update account event", %{instance: instance} do
      {:ok, %{source: src, source_idempk: sid} = create_event} =
        EventStore.create(
          account_event_attrs(%{
            instance_address: instance.address,
            payload: account_data_attrs(%{name: "Old Name"})
          })
        )

      CreateAccountEvent.process(create_event)

      {:ok, update_event} =
        EventStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            source: src,
            source_idempk: sid,
            update_idempk: "1",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:ok, %Account{} = account, %Event{event_queue_item: eqi} = e} =
               UpdateAccountEvent.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :processed
      assert account.address == "account:1"
      assert account.name == "New Name"
    end

    test "moves to dead_letter when create account event does not exist", %{instance: instance} do
      {:ok, update_event} =
        EventStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            source: "src",
            source_idempk: "sid",
            update_idempk: "1",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:error, %Event{event_queue_item: eqi} = e} =
               UpdateAccountEvent.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :dead_letter
    end

    test "stays pending when create account event is not yet processed", %{instance: instance} do
      {:ok, %{source: src, source_idempk: sid}} =
        EventStore.create(
          account_event_attrs(%{
            instance_address: instance.address,
            payload: account_data_attrs(%{name: "Old Name"})
          })
        )

      {:ok, update_event} =
        EventStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            source: src,
            source_idempk: sid,
            update_idempk: "1",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:error, %Event{event_queue_item: eqi} = e} =
               UpdateAccountEvent.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :pending
    end

    test "moves to dead letter when create event is in dead letter", %{instance: instance} do
      {:ok, %{source: src, source_idempk: sid, event_queue_item: event_qi}} =
        EventStore.create(
          account_event_attrs(%{
            instance_address: instance.address,
            payload: %AccountData{address: "sss", type: :asset, currency: :EUR}
          })
        )

      from(eqi in EventQueueItem, where: eqi.id == ^event_qi.id)
      |> Repo.update_all(set: [status: :dead_letter])


      {:ok, update_event} =
        EventStore.create(
          account_event_attrs(%{
            action: :update_account,
            instance_address: instance.address,
            source: src,
            source_idempk: sid,
            update_idempk: "1",
            payload: %AccountData{name: "New Name"}
          })
        )

      assert {:error, %Event{event_queue_item: eqi} = e} =
               UpdateAccountEvent.process(update_event)

      assert e.id == update_event.id
      assert eqi.status == :dead_letter
    end
  end
end
