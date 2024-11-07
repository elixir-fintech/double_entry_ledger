defmodule DoubleEntryLedger.OccRetry do
  @moduledoc """
  Helper functions for handling OCC conflicts.
  """
  alias DoubleEntryLedger.{Event, EventStore}
  @type retry_schema() :: Event.t()

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)
  @retry_interval Application.compile_env(:double_entry_ledger, :retry_interval, 200)

  @doc """
  Retries a function call a number of times in case of an OCC conflict.
  """
  @spec retry(fun(), [retry_schema(), ...]) :: {:error, String.t()} | {:ok, any()}
  def retry(fun, [schema| _] = payload) when is_struct(schema, Event) do
    event_retry(fun, payload, @max_retries)
  end

  def retry(_fun, _args) do
    {:error, "Not implemented"}
  end

  @doc """
  Retries a function call a number of times in case of an OCC conflict for an event.
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
