defmodule DoubleEntryLedger.OccRetryTest do
  @moduledoc """
  This module tests the OccRetry module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.OccRetry

  doctest OccRetry

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)

  describe "delay/1" do
    test "returns delay" do
      assert 20 = OccRetry.delay(@max_retries - 1)
    end

    test "delay gets bigger with each attempt" do
      assert 30 = OccRetry.delay(@max_retries - 2)
    end
  end

  describe "set_delay_timer/1" do
    test "waits for the correct amount of time" do
      attempts = 3
      delay = OccRetry.delay(attempts)
      start_time = :os.system_time(:millisecond)
      OccRetry.set_delay_timer(attempts)
      end_time = :os.system_time(:millisecond)
      assert end_time - start_time >= delay
    end
  end

  describe "max_retries/0" do
    test "returns the correct max retries" do
      assert OccRetry.max_retries() == @max_retries
    end
  end

  describe "occ_error_message/1" do
    test "returns the correct error message" do
      attempts = 3

      expected_message =
        "OCC conflict detected, retrying after #{OccRetry.delay(attempts)} ms... #{attempts - 1} attempts left"

      assert OccRetry.occ_error_message(attempts) == expected_message
    end
  end

  describe "occ_final_error_message/0" do
    test "returns the correct final error message" do
      expected_message = "OCC conflict: Max number of #{@max_retries} retries reached"
      assert OccRetry.occ_final_error_message() == expected_message
    end
  end
end
