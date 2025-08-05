defmodule DoubleEntryLedger.EventWorker do
  @moduledoc """
  Processes accounting events to create and update double-entry ledger transactions.

  This module serves as the main interface for event processing in the double-entry
  bookkeeping system. It handles two primary workflows:

  1. Processing new event maps received from external systems
  2. Processing existing events already stored in the system by their UUID

  The worker supports events with actions `:create_transaction` and `:update`, delegating the actual
  processing to specialized handler modules. Create events generate new transactions,
  while update events modify existing transactions.

  Each processed event results in appropriate debits and credits to ledger accounts,
  maintaining the fundamental accounting equation: Assets = Liabilities + Equity.

  Note: Events must be in the `:pending` state to be eligible for processing.
  """
  alias Ecto.Changeset

  alias DoubleEntryLedger.{
    Event,
    Transaction
  }

  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.EventWorker.ProcessEvent
  alias DoubleEntryLedger.EventQueue.Scheduling

  import ProcessEvent, only: [process_event: 1, process_event_map: 1, process_event_map_no_save_on_error: 1]

  @type success_tuple :: {:ok, Transaction.t(), Event.t()}
  @type error_tuple :: {:error, Event.t() | Changeset.t() | String.t()}

  @doc """
  Processes a new event map by delegating to the appropriate handler.

  Takes an event map (typically from an external system) and processes it according
  to its action type. The event map is validated, transformed into the proper format,
  and then processed to create or update transactions in the double-entry ledger.

  ## Parameters

    - `event_map`: A structured map containing event data with fields like:
      - `:action` - The event action (`:create_transaction` or `:update`)
      - `:instance_id` - The instance this event belongs to
      - `:data` - The transaction data for processing

  ## Returns

    - `{:ok, transaction, event}` - Successfully processed the event, returning both
      the created/updated transaction and the final event record
    - `{:error, event}` - Failed to process the event, with the event containing error details
    - `{:error, changeset}` - Failed validation, with changeset containing validation errors
    - `{:error, reason}` - Failed with a general error, with reason explaining the failure

  ## Examples

      # Process a create event for a new transaction
      iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, Transaction, Event}
      iex> alias DoubleEntryLedger.Event.EventMap
      iex> {:ok, instance} = InstanceStore.create(%{name: "instance1"})
      iex> {:ok, account1} = AccountStore.create(%{name: "account1", instance_id: instance.id, type: :asset, currency: :EUR})
      iex> {:ok, account2} = AccountStore.create(%{name: "account2", instance_id: instance.id, type: :liability, currency: :EUR})
      iex> event_map = %EventMap{instance_id: instance.id,
      ...>  source: "s1", source_idempk: "1", action: :create_transaction,
      ...>  transaction_data: %{status: :pending, entries: [
      ...>      %{account_id: account1.id, amount: 100, currency: :EUR},
      ...>      %{account_id: account2.id, amount: 100, currency: :EUR},
      ...>  ]}}
      iex> {:ok, %Transaction{status: :pending}, %Event{event_queue_item: %{status: :processed}}} = EventWorker.process_new_event(event_map)

  """
  @spec process_new_event(EventMap.t()) ::
          success_tuple() | error_tuple()
  def process_new_event(%EventMap{} = event_map) do
    process_event_map(event_map)
  end

  @spec process_new_event_no_save_on_error(EventMap.t()) ::
          success_tuple() | error_tuple()
  def process_new_event_no_save_on_error(%EventMap{} = event_map) do
    process_event_map_no_save_on_error(event_map)
  end

  @doc """
  Retrieves and processes an event by its UUID, claiming it for processing.

  This function fetches the event from the event store by its UUID and attempts to claim it for processing.
  Only events in a claimable state (e.g., `:pending`) will be processed. The function is useful for
  processing events that were previously stored but not yet processed, or for retrying failed events.

  ## Parameters
    - `uuid`: The UUID string identifying the event to process
    - `processor_id`: (optional) The processor identifier (defaults to "manual")

  ## Returns
    - `{:ok, transaction, event}`: Successfully processed the event, returning both the transaction and event
    - `{:error, :event_not_found}`: No event found with the given UUID
    - `{:error, event}`: Failed to process the event, with the event containing error details
    - `{:error, changeset}`: Failed validation, with changeset containing validation errors
    - `{:error, reason}`: Failed with a general error, with reason explaining the failure

  ## Examples

      # Process an existing pending event
      iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, EventStore, Transaction, Event}
      iex> alias DoubleEntryLedger.Event.EventMap
      iex> {:ok, instance} = InstanceStore.create(%{name: "instance1"})
      iex> {:ok, account1} = AccountStore.create(%{name: "account1", instance_id: instance.id, type: :asset, currency: :EUR})
      iex> {:ok, account2} = AccountStore.create(%{name: "account2", instance_id: instance.id, type: :liability, currency: :EUR})
      iex> {:ok, event} = EventStore.create(%{instance_id: instance.id,
      ...>  source: "s1", source_idempk: "1", action: :create_transaction,
      ...>  transaction_data: %{status: :pending, entries: [
      ...>      %{account_id: account1.id, amount: 100, currency: :EUR},
      ...>      %{account_id: account2.id, amount: 100, currency: :EUR},
      ...>  ]}})
      iex> {:ok, %Transaction{status: :pending}, %Event{event_queue_item: %{status: :processed}}} = EventWorker.process_event_with_id(event.id)

      # Attempt to process a non-existent event
      iex> EventWorker.process_event_with_id("550e8400-e29b-41d4-a716-446655440000")
      {:error, :event_not_found}
  """
  @spec process_event_with_id(Ecto.UUID.t(), String.t() | nil) ::
          success_tuple() | error_tuple()
  def process_event_with_id(uuid, processor_id \\ "manual") do
    case Scheduling.claim_event_for_processing(uuid, processor_id) do
      {:ok, event} -> process_event(event)
      {:error, error} -> {:error, error}
    end
  end
end
