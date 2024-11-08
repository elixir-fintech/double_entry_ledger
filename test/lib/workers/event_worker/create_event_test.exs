defmodule DoubleEntryLedger.CreateEventTest do
  @moduledoc """
  This module tests the CreateEvent module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.CreateEvent

  doctest CreateEvent

  describe "process_create_event/1" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      %{event: event} = create_event(ctx)

      {:ok, transaction, processed_event } = CreateEvent.process_create_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end
  end
end
