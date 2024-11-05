defmodule DoubleEntryLedger.OccRetryTest do
  @moduledoc """
  This module tests the OccRetry module.
  """
  use ExUnit.Case
      alias DoubleEntryLedger.Event
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{OccRetry, Repo}
  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  describe "retry/3" do
    test "it implements retry for Event" do
      assert {:ok, 1} = OccRetry.retry(fn (_, _) -> {:ok, 1} end, [%Event{}, %{}])
    end

    test "does not implement retry for anonymous struct" do
      assert {:error, "Not implemented"} = OccRetry.retry(fn (_, _) -> {:ok, 1} end, [%{}, %{}])
    end
  end


  describe "event_retry/3" do
    setup [:create_instance, :create_accounts]

    test "retry for 0 attempts left" do
      assert {:error, "OCC conflict: Max number of 2 retries reached"  } = OccRetry.event_retry({}, [%{}, %{}], 0)
    end

    test "retry for 1 attempt left", ctx do
      %{event: event} = create_event(ctx)

      func = fn _event, _map ->
        raise Ecto.StaleEntryError,
          action: :update,
          changeset: %{data: ""}
        end
      assert {:error, "OCC conflict: Max number of 2 retries reached"  } = OccRetry.event_retry(func, [event, %{}], 1)
      assert [%{"message" => "OCC conflict detected, retrying after 20 ms... 0 attempts left"}] = Repo.reload(event).errors
    end

    test "retry for 2 accumulates errors", ctx do
      %{event: event} = create_event(ctx)

      func = fn _event, _map ->
        raise Ecto.StaleEntryError,
          action: :update,
          changeset: %{data: ""}
        end
      assert {:error, "OCC conflict: Max number of 2 retries reached"  } = OccRetry.event_retry(func, [event, %{}], 2)
      assert [
        %{"message" => "OCC conflict detected, retrying after 20 ms... 0 attempts left"},
        %{"message" => "OCC conflict detected, retrying after 10 ms... 1 attempts left"}] = Repo.reload(event).errors
    end
  end
end
