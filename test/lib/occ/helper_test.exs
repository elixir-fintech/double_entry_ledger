defmodule DoubleEntryLedger.Occ.HelperTest do
  @moduledoc """
  This module tests the OccRetry module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Occ.Helper, as: OccRetry

  doctest OccRetry

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)

  @retry_interval Application.compile_env(:double_entry_ledger, :retry_interval, 200)

  describe "delay/1" do
    test "first attempt has base retry interval" do
      assert @retry_interval = OccRetry.delay(@max_retries)
    end

    test "delay doubles with each successive retry" do
      delays = Enum.map(@max_retries..1//-1, &OccRetry.delay/1)

      Enum.chunk_every(delays, 2, 1, :discard)
      |> Enum.each(fn [earlier, later] ->
        assert later == earlier * 2
      end)
    end

    test "last attempt has highest delay" do
      first_delay = OccRetry.delay(@max_retries)
      last_delay = OccRetry.delay(1)
      assert last_delay > first_delay
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
end
