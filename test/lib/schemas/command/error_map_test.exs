defmodule DoubleEntryLedger.Command.ErrorMapTest do
  @moduledoc """
  Tests for the Command Error Map
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Command.ErrorMap

  doctest DoubleEntryLedger.Command.ErrorMap

  # The class is the only part of a persisted failure that reaches telemetry
  # (`CommandQueue.Scheduling.emit_persisted_failure/3`), so it is decided here,
  # once, where the entry is built, and carried as a field rather than parsed
  # back out of the message by the reader.
  describe "build_error/2 class" do
    test "is the segment before the first separator" do
      assert ErrorMap.build_error("Task crashed: boom").class == "Task crashed"
    end

    test "stops at the first separator, not a later one" do
      error = ErrorMap.build_error("Task crashed: MatchError: no match: %{amount: 4200}")

      assert error.class == "Task crashed"
    end

    test "is the whole message when it carries no separator" do
      assert ErrorMap.build_error("unbalanced").class == "unbalanced"
    end

    # Unchanged from the read-time split this replaced: an inspected term is
    # classed by the same first-separator rule as any other message, which for
    # a map means everything before its first value. Blunt, but it is the rule
    # that guarantees no detail escapes, and it cuts short rather than long.
    test "classes a non-binary error from its inspected form" do
      assert ErrorMap.build_error(%{reason: :not_found}).class == "%{reason"
    end

    test "keeps the full message beside the class" do
      error = ErrorMap.build_error("Task crashed: %{amount: 4200}")

      assert error.message == "Task crashed: %{amount: 4200}"
    end

    test "uses the supplied timestamp" do
      now = ~U[2026-01-01 00:00:00.000000Z]

      assert ErrorMap.build_error("boom", now).inserted_at == now
    end
  end
end
