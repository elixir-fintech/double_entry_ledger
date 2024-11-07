defmodule DoubleEntryLedger.OccRetry do
  @moduledoc """
  Provides functions to handle Optimistic Concurrency Control (OCC) conflicts by retrying operations.

  This module is responsible for retrying database operations that may fail due to OCC conflicts,
  particularly when multiple processes attempt to update the same data concurrently.
  """
  alias DoubleEntryLedger.{Event, EventStore}
  @type retry_schema() :: Event.t()

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)
  @retry_interval Application.compile_env(:double_entry_ledger, :retry_interval, 200)

  @doc """
  Retries a function call a number of times in case of an OCC conflict.

  ## Parameters

    - `fun` - The function to retry.
    - `payload` - The list of arguments to pass to the function. The first element must be a schema struct.

  ## Returns

    - `{:ok, result}` if the function call succeeds.
    - `{:error, reason}` if all retries fail or an error occurs.
  """
  @spec retry(fun(), [retry_schema(), ...]) :: {:error, String.t()} | {:ok, any()}
  def retry(fun, [schema| _] = payload) when is_struct(schema, Event) do
    event_retry(fun, payload, @max_retries)
  end

  def retry(_fun, _args) do
    {:error, "Not implemented"}
  end

  @doc """
  Retries a function call a specified number of times in case of an OCC conflict for an event.

  ## Parameters

    - `fun` - The function to retry.
    - `payload` - The list of arguments to pass to the function. The first element must be an `%Event{}` struct.
    - `attempts` - The number of remaining retry attempts.

  ## Returns

    - `{:ok, result}` if the function call succeeds.
    - `{:error, reason}` if all retries fail or an error occurs.
  """
  @spec event_retry(fun(), [retry_schema(), ...], integer()) :: {:error, String.t()} | {:ok, any()}
  def event_retry(fun, [event | args] = payload, attempts) when attempts > 0 do
    try do
      apply(fun, payload)
    rescue
      Ecto.StaleEntryError ->
        delay = (@max_retries - attempts + 1) * @retry_interval
        {:ok, updated_event} = EventStore.add_error(event, "OCC conflict detected, retrying after #{delay} ms... #{attempts - 1} attempts left")
        :timer.sleep(delay)
        event_retry(fun, [updated_event | args], attempts - 1)
    end
  end

  def event_retry(_fun, _args, 0) do
    {:error, "OCC conflict: Max number of #{@max_retries} retries reached"}
  end
end
