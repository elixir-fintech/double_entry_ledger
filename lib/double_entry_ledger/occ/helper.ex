defmodule DoubleEntryLedger.Occ.Helper do
  @moduledoc """
  Helpers for the OCC retry loop driven by `DoubleEntryLedger.Occ.Processor`.

  * **Backoff**: `delay/1` grows the wait exponentially with each attempt and
    `set_delay_timer/1` sleeps for it.
  * **Error tracking**: `update_error_map/3` accumulates the retry messages and
    `occ_timeout_changeset/2` marks a command as `:occ_timeout` once the
    attempts are exhausted.

  ## Configuration

    * `:max_retries` - maximum number of OCC attempts (default: 5)
    * `:retry_interval` - base backoff interval in milliseconds (default: 200)
  """

  import DoubleEntryLedger.Command.ErrorMap
  alias DoubleEntryLedger.Command.ErrorMap
  alias DoubleEntryLedger.{Command, CommandQueueItem}
  alias Ecto.Changeset
  import Ecto.Changeset, only: [put_assoc: 3, change: 2]

  defdelegate create_error_map(command), to: DoubleEntryLedger.Command.ErrorMap

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
  Calculates the delay duration based on the number of attempts using exponential backoff.
  Can be configured via the `:retry_interval` application environment.
  The delay doubles with each successive retry.

  ## Parameters

    - `attempts`: The current attempt number (counts down from max_retries).

  ## Examples
      iex> DoubleEntryLedger.Occ.Helper.delay(4)
      20
      iex> DoubleEntryLedger.Occ.Helper.delay(2)
      80
  """
  @spec delay(integer()) :: number()
  def delay(attempts) do
    exponent = max_retries() - attempts
    trunc(retry_interval() * :math.pow(2, exponent))
  end

  @doc """
  Returns the maximum number of retries allowed.
  Can be configured via the `:max_retries` application environment.

  ## Examples

      iex> DoubleEntryLedger.Occ.Helper.max_retries()
      5
  """
  @spec max_retries() :: integer()
  def max_retries, do: Application.get_env(:double_entry_ledger, :max_retries, 5)

  @doc """
  Returns the retry interval in milliseconds.
  Can be configured via the `:retry_interval` application environment.

  ## Examples

      iex> DoubleEntryLedger.Occ.Helper.retry_interval()
      10
  """
  @spec retry_interval() :: integer()
  def retry_interval, do: Application.get_env(:double_entry_ledger, :retry_interval, 200)

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

      iex> error_map = %DoubleEntryLedger.Command.ErrorMap{errors: [], retries: 0, steps_so_far: %{}}
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
      errors: build_errors(error_map.errors, message),
      steps_so_far: steps_so_far,
      retries: error_map.retries + 1,
      save_on_error: error_map.save_on_error
    }
  end

  @doc """
  Creates a changeset to mark a command as timed out due to OCC conflicts.

  This function prepares a changeset that updates a command to the `:occ_timeout` status,
  recording the error information from the error map and updating the retry count.

  ## Parameters

    - `command` (`Command.t()`): The command to update
    - `%{errors: errors, retries: retries}`: An error map containing:
      - `errors`: List of error messages accumulated during retry attempts
      - `retries`: Number of retry attempts made

  ## Returns

    - `Ecto.Changeset.t()`: A changeset ready to update the command with timeout information

  """
  @spec occ_timeout_changeset(Command.t(), ErrorMap.t()) ::
          Changeset.t()
  def occ_timeout_changeset(
        %{command_queue_item: command_queue_item} = command,
        error_map
      ) do
    command
    |> change(%{})
    |> put_assoc(
      :command_queue_item,
      build_occ_timeout_changeset(command_queue_item, error_map)
    )
  end

  def occ_timeout_changeset(command, error_map) do
    command
    |> change(%{})
    |> put_assoc(
      :command_queue_item,
      build_occ_timeout_changeset(%CommandQueueItem{}, error_map)
    )
  end

  @doc """
  Generates an appropriate error message for OCC conflicts.

  Creates different messages depending on the number of attempts remaining:
  - When attempts > 1, shows a retry message with delay time and attempts left
  - When attempts <= 1, shows a final timeout message

  ## Parameters

    - `attempts` (`integer()`): The current attempt number

  ## Returns

    - `String.t()`: A formatted error message

  ## Examples

      iex> DoubleEntryLedger.Occ.Helper.occ_error_message(3)
      "OCC conflict detected, retrying after 40 ms... 2 attempts left"

      iex> DoubleEntryLedger.Occ.Helper.occ_error_message(1)
      "OCC conflict: Max number of 5 retries reached"
  """
  @spec occ_error_message(integer()) :: String.t()
  def occ_error_message(attempts) when attempts > 1 do
    "OCC conflict detected, retrying after #{delay(attempts)} ms... #{attempts - 1} attempts left"
  end

  def occ_error_message(_attempts) do
    "OCC conflict: Max number of #{max_retries()} retries reached"
  end

  @spec build_occ_timeout_changeset(CommandQueueItem.t(), ErrorMap.t()) ::
          Changeset.t()
  defp build_occ_timeout_changeset(command_queue_item, %{errors: errors, retries: retries}) do
    command_queue_item
    |> change(%{
      status: :occ_timeout,
      occ_retry_count: retries,
      errors: errors
    })
  end
end
