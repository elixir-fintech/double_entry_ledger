defmodule DoubleEntryLedger.EventWorker.ProcessEvent do
  @moduledoc """
  Processes accounting events and transforms them into ledger transactions.

  This module serves as the primary entry point for processing double-entry ledger events.
  It handles two main scenarios:

  - Processing existing `Event` structures already in the system
  - Processing raw event maps that need to be validated and converted

  The module supports different event actions (create/update) and ensures that only
  events in the appropriate state are processed. It delegates specialized processing
  to dedicated handler modules based on the event action.

  Event processing follows these steps:
  1. Validate the event status and action
  2. Delegate to the appropriate handler module
  3. Create or update the associated transaction records
  4. Update the event status to reflect the result
  """

  alias Ecto.Changeset

  alias DoubleEntryLedger.{
    CreateEvent,
    Event,
    Transaction,
    UpdateEvent
  }

  alias DoubleEntryLedger.Event.EventMap

  alias DoubleEntryLedger.EventWorker.{
    ProcessEventMap,
    UpdateEvent,
    CreateEvent
  }

  import ProcessEventMap, only: [process_map: 1]
  import CreateEvent, only: [process_create_event: 1]
  import UpdateEvent, only: [process_update_event: 1]

  @actions Event.actions()

  @doc """
  Processes a pending event based on its action type.

  This function takes an existing Event struct and processes it according to its
  action type. Only events in the processing state can be processed. The function
  delegates to specialized handlers for different action types (create, update).

  ## Parameters
    - `event` - An %Event{} struct in the processing state

  ## Returns
    - `{:ok, transaction, event}` - Successfully processed the event, returning the
      resulting transaction and the updated event
    - `{:error, event}` - Failed to process the event, with the event containing error details
    - `{:error, changeset}` - Failed to process the event, with changeset containing validation errors
    - `{:error, reason}` - Failed to process the event, with reason explaining the failure

  """
  @spec process_event(Event.t()) ::
          {:ok, Transaction.t(), Event.t()}
          | {:error, Event.t() | Changeset.t() | String.t() | atom()}
  def process_event(%Event{event_queue_item: %{status: :processing}, action: :create} = event) do
    process_create_event(event)
  end

  def process_event(%Event{event_queue_item: %{status: :processing}, action: :update} = event) do
    process_update_event(event)
  end

  def process_event(%Event{event_queue_item: %{status: :processing}, action: _} = _event) do
    {:error, :action_not_supported}
  end

  def process_event(%Event{} = _event) do
    {:error, :event_not_in_processing_state}
  end

  @doc """
  Processes an event map by validating it and converting it to a proper Event record.

  This function serves as the entry point for processing external event data. It
  validates that the action is supported before delegating to the appropriate handler.
  The event map is transformed into a properly structured Event record, and the
  associated transaction is created or updated.

  ## Parameters
    - `event_map` - A map containing event data with at least an :action field

  ## Returns
    - `{:ok, transaction, event}` - Successfully processed the event map, returning
      the resulting transaction and the created event
    - `{:error, event}` - Failed to process the event, with the event containing error details
    - `{:error, changeset}` - Failed to process the event, with changeset containing validation errors
    - `{:error, reason}` - Failed to process the event, with reason explaining the failure

  """
  @spec process_event_map(EventMap.t()) ::
          {:ok, Transaction.t(), Event.t()}
          | {:error, Event.t() | Changeset.t() | String.t() | atom()}
  def process_event_map(%{action: action} = event_map) when action in @actions do
    process_map(event_map)
  end

  def process_event_map(_event_map) do
    {:error, :action_not_supported}
  end
end
