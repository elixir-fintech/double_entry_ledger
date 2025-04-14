defmodule DoubleEntryLedger.OccRetry do
  @moduledoc """
  Provides helper functions to handle Optimistic Concurrency Control (OCC) retries.
  Retry logic is implemented in the relevant modules.
  """

  import DoubleEntryLedger.Event.ErrorMap
  alias DoubleEntryLedger.Event.ErrorMap

  defdelegate create_error_map(event), to: DoubleEntryLedger.Event.ErrorMap

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)
  @retry_interval Application.compile_env(:double_entry_ledger, :retry_interval, 200)

  @doc """
  Pauses execution for a calculated delay based on the number of attempts.

  ## Parameters

    - `attempts`: The current attempt number.

  ## Examples

      iex> DoubleEntryLedger.OccRetry.set_delay_timer(2)
      :ok
  """
  @spec set_delay_timer(integer()) :: :ok
  def set_delay_timer(attempts) do
    delay(attempts)
    |> :timer.sleep()
  end

  @doc """
  Calculates the delay duration based on the number of attempts.
  Can be configured via the `:retry_interval` application environment.
  The delay increases with each attempt.

  ## Parameters

    - `attempts`: The current attempt number.

  ## Examples
      iex> DoubleEntryLedger.OccRetry.delay(4)
      20
      iex> DoubleEntryLedger.OccRetry.delay(2)
      40
  """
  @spec delay(integer()) :: number()
  def delay(attempts) do
    (@max_retries - attempts + 1) * @retry_interval
  end

  @doc """
  Returns the maximum number of retries allowed.
  Can be configured via the `:max_retries` application environment.

  ## Examples

      iex> DoubleEntryLedger.OccRetry.max_retries()
      5
  """
  @spec max_retries() :: integer()
  def max_retries(), do: @max_retries

  @doc """
  Returns the retry interval in milliseconds.
  Can be configured via the `:retry_interval` application environment.

  ## Examples

      iex> DoubleEntryLedger.OccRetry.retry_interval()
      10
  """
  @spec retry_interval() :: integer()
  def retry_interval(), do: @retry_interval

  @doc """
  Generates an error message for an OCC conflict with retries remaining.

  ## Parameters

    - `attempts`: The current attempt number.

  ## Examples

      iex> DoubleEntryLedger.OccRetry.occ_error_message(2)
      "OCC conflict detected, retrying after 40 ms... 1 attempts left"

      iex> DoubleEntryLedger.OccRetry.occ_error_message(1)
      "OCC conflict: Max number of 5 retries reached"
  """
  @spec occ_error_message(integer()) :: String.t()
  def occ_error_message(attempts) when attempts > 1 do
    "OCC conflict detected, retrying after #{delay(attempts)} ms... #{attempts - 1} attempts left"
  end

  def occ_error_message(_attempts) do
    "OCC conflict: Max number of #{@max_retries} retries reached"
  end

  @spec update_error_map(ErrorMap.t(), integer(), map()) :: ErrorMap.t()
  def update_error_map(error_map, attempts, steps_so_far) do
    message = occ_error_message(attempts)

    %ErrorMap{
      errors: build_errors(message, error_map.errors),
      steps_so_far: steps_so_far,
      retries: error_map.retries + 1
    }
  end
end
