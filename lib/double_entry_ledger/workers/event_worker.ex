defmodule DoubleEntryLedger.EventWorker do
  @moduledoc """
  The `EventWorker` module processes events to create and update transactions,
  adjusting the balances of accounts in the ledger.

  It handles events with actions `:create` and `:update`, processing them accordingly.
  Functions are provided to process new events structs and existing events by UUID.

  Existing events must be in the `:pending` state to be processed.
  """
  alias DoubleEntryLedger.{
    Event, EventStore, Transaction
  }

  alias DoubleEntryLedger.EventWorker.ProcessEvent


  import ProcessEvent, only: [process_event: 1, process_event_map: 1]

  @doc """
  Processes a new event map by inserting it into the event store and handling it.

  The event is inserted with a `:pending` status and then processed based on its action.
  If successful, returns the associated transaction and updated event.

  ## Parameters

    - `event_map`: A map representing the event to process.

  ## Returns

    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_new_event(Event.event_map()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_new_event(%{} = event_map)  do
    process_event_map(event_map)
  end

  @doc """
  Retrieves and processes an event by its UUID.

  Fetches the event from the store and processes it according to its action.
  Returns the resulting transaction and updated event on success.

  ## Parameters

    - `uuid`: The UUID of the event to process.

  ## Returns

    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` if the event is not found or processing fails.
  """
  @spec process_event_with_id(Ecto.UUID.t()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_event_with_id(uuid) do
    case EventStore.get_event(uuid) do
      {:ok, event} -> process_event(event)
      {:error, reason} -> {:error, reason}
    end
  end

end
