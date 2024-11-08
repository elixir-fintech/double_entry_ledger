defmodule DoubleEntryLedger.EventWorker do
  @moduledoc """
  This module processes events and updates the balances of the accounts
  """

  alias DoubleEntryLedger.{
    CreateEvent, Event, Transaction, UpdateEvent
  }

  import CreateEvent, only: [process_create_event: 1]
  import UpdateEvent, only: [process_update_event: 1]

  @spec process_event(Event.t()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_event(%Event{status: :pending, action: action } = event) do
    case action do
      :create -> process_create_event(event)
      :update -> process_update_event(event)
      _ -> {:error, "Action is not supported"}
    end
  end

  def process_event(_event) do
    {:error, "Event is not in pending state"}
  end
end
