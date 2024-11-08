defmodule DoubleEntryLedger.EventWorker do
  @moduledoc """
  Processes events to create and update Transactions
  that update the balances of accounts.

  Handles events with actions `:create` and `:update`, and updates the ledger accordingly.
  """

  alias DoubleEntryLedger.{
    CreateEvent, Event, Transaction, UpdateEvent
  }

  import CreateEvent, only: [process_create_event: 1]
  import UpdateEvent, only: [process_update_event: 1]

  @doc """
  Processes an event based on its action and status.

  ## Parameters

    - `event`: The `%Event{}` struct to be processed.

  ## Returns

    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
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
