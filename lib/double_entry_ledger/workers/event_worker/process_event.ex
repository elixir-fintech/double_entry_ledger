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

  alias DoubleEntryLedger.{Event, EventWorker}

  alias DoubleEntryLedger.Event.EventMap

  alias DoubleEntryLedger.EventWorker.{
    UpdateEventMap,
    UpdateEvent,
    UpdateEventMapNoSaveOnError,
    CreateTransactionEvent,
    CreateEventMapNoSaveOnError,
    CreateEventMap
  }

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
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_event(%Event{event_queue_item: %{status: :processing}, action: :create_transaction} = event) do
    CreateTransactionEvent.process(event)
  end

  def process_event(%Event{event_queue_item: %{status: :processing}, action: :update} = event) do
    UpdateEvent.process(event)
  end

  def process_event(%Event{event_queue_item: %{status: :processing}, action: _} = _event) do
    {:error, :action_not_supported}
  end

  def process_event(%Event{} = _event) do
    {:error, :event_not_in_processing_state}
  end

  @doc """
  Processes an event map by validating and dispatching it to the correct handler.

  This function is the entry point for processing external event data. It checks the `:action` field
  and delegates to the appropriate handler for `:create_transaction` or `:update` actions. The event map is
  transformed into a structured Event record, and the associated transaction is created or updated.

  ## Parameters
    - `event_map`: A map containing event data, including an `:action` key

  ## Returns
    - `{:ok, transaction, event}`: On successful processing
    - `{:error, event}`: If processing failed, with the event containing error details
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: For other errors or unsupported actions
  """
  @spec process_event_map(EventMap.t()) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_event_map(%{action: :create_transaction} = event_map) do
    CreateEventMap.process(event_map)
  end

  def process_event_map(%{action: :update} = event_map) do
    UpdateEventMap.process(event_map)
  end

  def process_event_map(_event_map) do
    {:error, :action_not_supported}
  end

  @doc """
  Processes an event map without saving on error, dispatching to the correct handler.

  This function is similar to `process_event_map/1` but is used in scenarios where errors should not
  be persisted to the database. It checks the `:action` field and delegates to the appropriate handler.

  ## Parameters
    - `event_map`: A map containing event data, including an `:action` key

  ## Returns
    - `{:ok, transaction, event}`: On successful processing
    - `{:error, event}`: If processing failed, with the event containing error details
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: For other errors or unsupported actions
  """
  @spec process_event_map_no_save_on_error(EventMap.t()) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_event_map_no_save_on_error(%{action: :create_transaction} = event_map) do
    CreateEventMapNoSaveOnError.process(event_map)
  end

  def process_event_map_no_save_on_error(%{action: :update} = event_map) do
    UpdateEventMapNoSaveOnError.process(event_map)
  end

  def process_event_map_no_save_on_error(_event_map) do
    {:error, :action_not_supported}
  end
end
