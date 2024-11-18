defmodule DoubleEntryLedger.EventWorker.ProcessEvent do
  @moduledoc """
  Provides functions to process ledger events and handle transactions accordingly.
  """

  alias DoubleEntryLedger.{
    CreateEvent, Event, Transaction, UpdateEvent
  }
  alias DoubleEntryLedger.EventWorker.{
    EventMap, UpdateEvent, CreateEvent
  }

  import EventMap, only: [process_map: 1]
  import CreateEvent, only: [process_create_event: 1]
  import UpdateEvent, only: [process_update_event: 1]

  @actions Event.actions()

  @doc """
  Processes a pending event by executing its associated action.

  ## Parameters
    - event: The `%Event{}` struct to be processed.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event(Event.t()) :: {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  def process_event(%Event{status: :pending, action: :create} = event) do
    process_create_event(event)
  end

  def process_event(%Event{status: :pending, action: :update} = event) do
    process_update_event(event)
  end

  def process_event(%Event{status: :pending, action: _} = _event) do
    {:error, "Action is not supported"}
  end

  def process_event(%Event{} = _event) do
    {:error, "Event is not in pending state"}
  end

  @doc """
  Processes an event map by creating an event record and handling the associated transaction.

  ## Parameters
    - event_map: A map representing the event data.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event_map(Event.event_map()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_event_map(%{action: action} = event_map) when action in @actions  do
    process_map(event_map)
  end

  def process_event_map(_event_map) do
    {:error, "Action is not supported"}
  end
end
