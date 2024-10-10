defmodule DoubleEntryLedger.EventStoreTest do
  @moduledoc """
  This module tests the EventStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.EventFixtures
  alias DoubleEntryLedger.{EventStore, Event}

  describe "insert_event/1" do
    test "inserts a new event" do
      assert {:ok, %Event{} = event} = EventStore.insert_event(event_attrs())
      assert event.status == :pending
      assert event.processed_at == nil
    end
  end

  describe "mark_as_processed/1" do
    test "marks an event as processed" do
      {:ok, event} = EventStore.insert_event(event_attrs())
      assert {:ok, %Event{} = updated_event} = EventStore.mark_as_processed(event)
      assert updated_event.status == :processed
      assert updated_event.processed_at != nil
    end
  end

  describe "mark_as_failed/2" do
    test "marks an event as failed" do
      {:ok, event} = EventStore.insert_event(event_attrs())
      assert {:ok, %Event{} = updated_event} = EventStore.mark_as_failed(event, "some reason")
      assert updated_event.status == :failed
      assert updated_event.processed_at == nil
      # TODO: Add assertion for logging reason if implemented
    end
  end
end
