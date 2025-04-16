defmodule DoubleEntryLedger.Occ.Helper do
  @moduledoc """
  Provides helper functions for managing Optimistic Concurrency Control (OCC) in the Double Entry Ledger system.

  This module contains utilities for implementing OCC retry logic, including backoff timing,
  error tracking, and retry state management. It offers a consistent framework for handling
  concurrent modification conflicts across the application.

  ## Key Functionality

  * **Retry Management**: Calculate and apply appropriate backoff delays
  * **Error Tracking**: Update error maps with retry information and messages
  * **Configuration**: Access OCC-related configuration settings like max retries
  * **Timing Utilities**: Calculate next retry times for event scheduling

  ## Configuration

  The module's behavior can be configured through the following application environment variables:

  * `:max_retries` - Maximum number of retry attempts (default: 5)
  * `:retry_interval` - Base interval for retries in milliseconds (default: 200)
  * `:next_retry_after_interval` - Time to wait before next retry attempt (default: max_retries * retry_interval)

  ## Usage Examples

  Setting a delay based on current attempt number:

      # Pause execution with exponential backoff
      DoubleEntryLedger.Occ.Helper.set_delay_timer(attempt_number)

  Updating an error map after an OCC conflict:

      updated_error_map = DoubleEntryLedger.Occ.Helper.update_error_map(
        existing_error_map,
        current_attempt_number,
        %{step_1: result_1, step_2: result_2}
      )

  Calculating timestamps for retry scheduling:

      {now, next_retry_time} = DoubleEntryLedger.Occ.Helper.get_now_and_next_retry_after()

  ## Implementation Notes

  This module uses a linear backoff strategy where retry intervals increase based on
  remaining attempts, helping to reduce contention over time while maintaining
  responsiveness for quick resolutions.
  """

  import DoubleEntryLedger.Event.ErrorMap
  alias DoubleEntryLedger.Event.ErrorMap

  defdelegate create_error_map(event), to: DoubleEntryLedger.Event.ErrorMap

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)
  @retry_interval Application.compile_env(:double_entry_ledger, :retry_interval, 200)
  @next_retry_after_interval Application.compile_env(
                               :double_entry_ledger,
                               :next_retry_after_interval,
                               @max_retries * @retry_interval
                             )

  @doc """
  Pauses execution for a calculated delay based on the number of attempts.

  ## Parameters

    - `attempts`: The current attempt number.

  ## Examples

      iex> DoubleEntryLedger.Occ.Helper.set_delay_timer(2)
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
      iex> DoubleEntryLedger.Occ.Helper.delay(4)
      20
      iex> DoubleEntryLedger.Occ.Helper.delay(2)
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

      iex> DoubleEntryLedger.Occ.Helper.max_retries()
      5
  """
  @spec max_retries() :: integer()
  def max_retries(), do: @max_retries

  @doc """
  Returns the retry interval in milliseconds.
  Can be configured via the `:retry_interval` application environment.

  ## Examples

      iex> DoubleEntryLedger.Occ.Helper.retry_interval()
      10
  """
  @spec retry_interval() :: integer()
  def retry_interval(), do: @retry_interval

  @doc """
  Calculates the current UTC datetime (`now`) and the next retry datetime
  based on the given time interval.

  ## Parameters

    - `time_interval` (non_neg_integer): The time interval in milliseconds
      to calculate the next retry datetime. Defaults to the value of
      `@next_retry_after_interval`.

  ## Returns

    - A tuple `{DateTime.t(), DateTime.t()}` where:
      - The first element is the current UTC datetime (`now`).
      - The second element is the next retry datetime, calculated by adding
        the `time_interval` to `now`.

  ## Examples

      iex> {now, next_retry} = DoubleEntryLedger.Occ.Helper.get_now_and_next_retry_after(1000)
      iex> next_retry > now
      true
  """
  @spec get_now_and_next_retry_after(non_neg_integer()) :: {DateTime.t(), DateTime.t()}
  def get_now_and_next_retry_after(time_interval \\ @next_retry_after_interval) do
    now = DateTime.utc_now()
    next_retry = DateTime.add(now, div(time_interval, 1000), :second)
    {now, next_retry}
  end

  @doc """
  Updates the given `ErrorMap` with a new error message, incrementing the retry count
  and updating the steps completed so far.

  ## Parameters

    - `error_map` (`ErrorMap.t()`): The current error map to be updated.
    - `attempts` (`integer()`): The number of attempts made so far.
    - `steps_so_far` (`map()`): A map representing the steps completed so far.

  ## Returns

    - `ErrorMap.t()`: The updated error map with the new error message, incremented retry count,
      and updated steps.

  ## Examples

      iex> error_map = %DoubleEntryLedger.Event.ErrorMap{errors: [], retries: 0, steps_so_far: %{}}
      iex> updated_error_map = DoubleEntryLedger.Occ.Helper.update_error_map(error_map, 3, %{step: "processing"})
      iex> updated_error_map.retries
      1
      iex> updated_error_map.steps_so_far
      %{step: "processing"}
      iex> length(updated_error_map.errors) > 0
      true
  """
  @spec update_error_map(ErrorMap.t(), integer(), map()) :: ErrorMap.t()
  def update_error_map(error_map, attempts, steps_so_far) do
    message = occ_error_message(attempts)

    %ErrorMap{
      errors: build_errors(message, error_map.errors),
      steps_so_far: steps_so_far,
      retries: error_map.retries + 1
    }
  end

  @spec occ_error_message(integer()) :: String.t()
  def occ_error_message(attempts) when attempts > 1 do
    "OCC conflict detected, retrying after #{delay(attempts)} ms... #{attempts - 1} attempts left"
  end

  def occ_error_message(_attempts) do
    "OCC conflict: Max number of #{@max_retries} retries reached"
  end
end
