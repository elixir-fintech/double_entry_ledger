defmodule DoubleEntryLedger.EventWorker do
  @moduledoc """
  Main event processing orchestrator for the Double Entry Ledger system.

  This module serves as the primary interface for processing accounting events that create
  and update double-entry ledger transactions and accounts. It coordinates between different
  processing strategies and delegates to specialized handler modules based on event types
  and actions.

  ## Processing Strategies

  The EventWorker supports multiple processing approaches:

  1. **New Event Maps** (`process_new_event/1`) - Direct processing of event maps from external systems. Event is saved for retry later if it fails.
  2. **No-Save-On-Error** (`process_new_event_no_save_on_error/1`) - Processing as above without saving the Event.
  3. **Stored Events** (`process_event_with_id/2`) - Processing events already in the database using atomic claiming

  ## Supported Event Types and Actions

  ### TransactionEventMap
  - `:create_transaction` - Creates new double-entry transactions with balanced entries
  - `:update_transaction` - Updates pending transactions only

  ### AccountEventMap
  - `:create_account` - Creates new ledger accounts with specified types and currencies
  - `:update_account` - Updates existing account properties

  ## Event Processing Flow

  ### Direct processing of event maps
  ```
  External System → EventMap → EventWorker → Specialized Handler → Transaction/Account
                                    ↓
                                  Event → EventQueueItem → Final State
                                                ↓
                                            Retryable State
  ```

  ### Stored event
  ```
  EventQueue → Event → EventWorker → Specialized Handler → Transaction/Account
                          ↓
                      EventQueueItem → Final State
                          ↓
                       Retryable State
  ```

  ## EventQueueItem State Management

  Events are tracked through `EventQueueItem` records that maintain processing state:

  ### Status Lifecycle
  - **`:pending`** → **`:processing`** → **`:processed`** (success path)
  - **`:pending`** → **`:processing`** → **`:failed`** (retryable error)
  - **`:pending`** → **`:processing`** → **`:occ_timeout`** (optimistic concurrency timeout)
  - **`:pending`** → **`:processing`** → **`:dead_letter`** (permanent failure)

  ### State Descriptions
  - **`:pending`** - Ready for processing, can be claimed
  - **`:processing`** - Currently being processed by a worker
  - **`:processed`** - Successfully completed
  - **`:failed`** - Failed but can be retried (temporary error)
  - **`:occ_timeout`** - Failed due to optimistic concurrency timeout, will be retried
  - **`:dead_letter`** - Permanently failed after exhausting retries

  ## Error Handling Strategies

  - **Standard Processing**: Errors update EventQueueItem status and error details for retry logic
  - **No-Save-On-Error**: Validation errors return changesets without Event and EventQueueItem persistence
  - **Event Claiming**: Uses optimistic locking on EventQueueItem to prevent concurrent processing
  - **Retry Logic**: Failed events can be automatically retried based on EventQueueItem configuration

  ## Handler Modules

  The EventWorker delegates to specialized handlers in the `DoubleEntryLedger.EventWorker` namespace:

  - `CreateTransactionEventMap` - New transaction creation from event maps
  - `UpdateTransactionEventMap` - Transaction updates from event maps
  - `CreateTransactionEvent` - Transaction creation from stored events
  - `UpdateTransactionEvent` - Transaction updates from stored events
  - `CreateTransactionEventMapNoSaveOnError` - Transaction creation without error persistence
  - `UpdateTransactionEventMapNoSaveOnError` - Transaction updates without error persistence
  - `CreateAccountEventMapNoSaveOnError` - Account creation without error persistence
  - `UpdateAccountEventMapNoSaveOnError` - Account updates without error persistence

  ## Examples

      # Process a new transaction event
      event_map = %TransactionEventMap{
        action: :create_transaction,
        instance_id: instance_id,
        source: "payment_system",
        source_idempk: "txn_123",
        payload: %{
          status: :pending,
          entries: [
            %{account_id: cash_account.id, amount: 100, currency: "USD"},
            %{account_id: revenue_account.id, amount: -100, currency: "USD"}
          ]
        }
      }

      {:ok, transaction, event} = EventWorker.process_new_event(event_map)
      # event.event_queue_item.status == :processed

      # Process an existing event by ID
      {:ok, transaction, event} = EventWorker.process_event_with_id(event_uuid)

      # Process without saving errors to EventQueueItem
      {:ok, transaction, event} = EventWorker.process_new_event_no_save_on_error(event_map)

  ## Architecture Notes

  - All processing maintains ACID properties through database transactions
  - Events are claimed atomically via EventQueueItem to prevent duplicate processing
  - Double-entry rules are enforced: debits must equal credits
  - Processing is idempotent based on source identifiers
  - Retry logic and error tracking handled through EventQueueItem state management
  """
  alias DoubleEntryLedger.EventWorker.CreateAccountEventMapNoSaveOnError
  alias Ecto.Changeset

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    Account
  }

  alias DoubleEntryLedger.Event.{TransactionEventMap, AccountEventMap}

  alias DoubleEntryLedger.EventWorker.{
    CreateTransactionEvent,
    UpdateTransactionEvent,
    CreateTransactionEventMap,
    UpdateTransactionEventMap,
    CreateAccountEventMapNoSaveOnError,
    UpdateAccountEventMapNoSaveOnError,
    CreateTransactionEventMapNoSaveOnError,
    UpdateTransactionEventMapNoSaveOnError
  }

  import DoubleEntryLedger.EventQueue.Scheduling, only: [claim_event_for_processing: 2]

  @typedoc """
  Success result from event processing operations.

  Contains the created or updated domain entity (Transaction or Account) along with
  the final Event record that tracks the processing state. The associated EventQueueItem
  will have status `:processed` upon successful completion.

  ## Fields

  - First element: The created/updated domain entity (`Transaction.t()` or `Account.t()`)
  - Second element: The `Event.t()` record with processing metadata and associated EventQueueItem

  ## EventQueueItem State on Success

  Upon success, the Event's EventQueueItem will have:
  - `status: :processed` - Indicates successful completion
  - `processing_completed_at: DateTime` - Timestamp of completion
  - `processor_id: String` - Identifier of the processing system
  - `errors: []` - No error information

  ## Examples

      {:ok, %Transaction{id: "123", status: :pending},
           %Event{event_queue_item: %{status: :processed, processing_completed_at: ~U[...]}}}

      {:ok, %Account{name: "Cash"},
           %Event{event_queue_item: %{status: :processed, processor_id: "api_worker"}}}
  """
  @type success_tuple :: {:ok, Transaction.t() | Account.t(), Event.t()}

  @typedoc """
  Error result from event processing operations.

  Represents various failure modes that can occur during event processing. The error
  content provides context about what went wrong and can be used for debugging,
  retry logic, or user feedback.

  ## Error Types

  - `Event.t()` - Processing failed after the event was created/updated. The Event's
    EventQueueItem will have status `:failed`, `:occ_timeout`, or `:dead_letter` based
    on the error type and retry configuration
  - `Changeset.t()` - Validation failed with detailed field-level error information
  - `String.t()` - General error with a descriptive message
  - `atom()` - Specific error codes like `:event_not_found` or `:action_not_supported`

  ## EventQueueItem Error States

  When processing fails with an Event error, the EventQueueItem may have:
  - `status: :failed` - Temporary failure, will be retried
  - `status: :occ_timeout` - Optimistic concurrency timeout, will be retried
  - `status: :dead_letter` - Permanent failure after exhausting retries
  - `errors: [%{...}]` - Array of error details with timestamps
  - `next_retry_after: DateTime` - When the next retry attempt should occur (for `:failed` status)

  ## Examples

      {:error, %Event{event_queue_item: %{status: :failed, errors: [%{message: "Insufficient balance"}]}}}
      {:error, %Changeset{errors: [amount: {"must be positive", []}]}}
      {:error, "Database connection failed"}
      {:error, :action_not_supported}
  """
  @type error_tuple :: {:error, Event.t() | Changeset.t() | String.t() | atom()}

  @doc """
  Processes a new event map by dispatching to the appropriate specialized handler.

  This is the primary entry point for processing events received from external systems.
  The function examines the event map's action and type to route it to the correct
  processing module. Each handler is responsible for validation, transformation, and
  persistence of the event and its resulting domain entities.

  ## Event Processing Flow

  1. **Event Creation** - Creates Event record and associated EventQueueItem with status `:pending`
  2. **Status Update** - Updates EventQueueItem to `:processing` during processing
  3. **Validation** - Ensures event map structure and data integrity
  4. **Transformation** - Converts event data into domain entities
  5. **Persistence** - Saves entities and updates EventQueueItem to `:processed`
  6. **Error Handling** - Updates EventQueueItem to appropriate error status (`:failed`, `:occ_timeout`, `:dead_letter`)

  ## Parameters

  - `event_map` - A validated event map struct with the following key fields:
    - `:action` - The operation type (`:create_transaction`, `:update_transaction`, `:create_account`, `:update_account`)
    - `:instance_id` - UUID of the ledger instance
    - `:source` - External system identifier
    - `:source_idempk` - Idempotency key from source system
    - `:payload` - Event-specific data for processing

  ## Returns

  - `success_tuple()` - Processing succeeded, returns the created entity and event with EventQueueItem status `:processed`
  - `error_tuple()` - Processing failed, returns error details and EventQueueItem in appropriate error state

  ## Supported Actions

  ### Transaction Events
  - `:create_transaction` - Creates new double-entry transactions with balanced entries
  - `:update_transaction` - Modifies existing transactions (status, metadata, etc.)

  ### Account Events
  - `:create_account` - Creates new ledger accounts with specified types and currencies
  - `:update_account` - Updates existing account properties

  ## Examples

      # Create a new transaction
      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{address: "instance1"})
      iex> {:ok, revenue_account} = DoubleEntryLedger.AccountStore.create(%{name: "Revenue", type: :liability, currency: :USD, instance_id: instance.id})
      iex> {:ok, cash_account} = DoubleEntryLedger.AccountStore.create(%{name: "Cash", type: :asset, currency: :USD, instance_id: instance.id})
      iex> event_map = %TransactionEventMap{
      ...>   action: :create_transaction,
      ...>   instance_id: instance.id,
      ...>   source: "payment_api",
      ...>   source_idempk: "payment_123",
      ...>   payload: %{
      ...>     status: :pending,
      ...>     entries: [
      ...>       %{account_id: cash_account.id, amount: 100, currency: "USD"},
      ...>       %{account_id: revenue_account.id, amount: 100, currency: "USD"}
      ...>     ]
      ...>   }
      ...> }
      iex> {:ok, transaction, event} = EventWorker.process_new_event(event_map)
      iex> transaction.status
      :pending
      iex> event.event_queue_item.status
      :processed

      # Unsupported action
      iex> invalid_map = %TransactionEventMap{action: :delete_transaction}
      iex> EventWorker.process_new_event(invalid_map)
      {:error, :action_not_supported}

  ## Error Scenarios

      # Validation failure (returns changeset)
      {:error, %Changeset{errors: [amount: {"must be positive", []}]}}

      # Business rule violation (returns event with error in EventQueueItem)
      {:error, %Event{event_queue_item: %{status: :failed, errors: [%{message: "Debit and credit amounts must balance"}]}}}

      # Optimistic concurrency timeout
      {:error, %Event{event_queue_item: %{status: :occ_timeout, next_retry_after: ~U[...]}}}

      # System error
      {:error, "Database connection timeout"}
  """
  @spec process_new_event(TransactionEventMap.t()) ::
          success_tuple() | error_tuple()
  def process_new_event(%TransactionEventMap{action: :create_transaction} = event_map) do
    CreateTransactionEventMap.process(event_map)
  end

  def process_new_event(%TransactionEventMap{action: :update_transaction} = event_map) do
    UpdateTransactionEventMap.process(event_map)
  end

  def process_new_event(_event_map), do: {:error, :action_not_supported}

  @doc """
  Processes an event map without persisting processing errors to the EventQueueItem.

  This function provides an alternative processing strategy for scenarios where you want
  to validate and process events but avoid storing error states in the EventQueueItem records.
  This is useful for:

  - **Validation Testing** - Check if an event would process successfully without side effects
  - **Batch Processing** - Process multiple events and handle errors in memory
  - **Preview Mode** - Show users what would happen without committing changes
  - **Error Recovery** - Retry processing without accumulating error history in EventQueueItem

  ## Key Differences from Standard Processing

  - **Error Persistence**: Validation errors return changesets instead of creating EventQueueItem error records
  - **Rollback Behavior**: Failed processing leaves no database traces
  - **Performance**: Slightly faster due to reduced database writes on errors
  - **State Management**: No EventQueueItem status transitions for validation failures

  ## EventQueueItem Behavior

  - **Success**: EventQueueItem created with status `:processed` (same as standard processing)
  - **Validation Errors**: No EventQueueItem created, changeset returned directly
  - **System Errors**: No EventQueueItem error state persisted

  ## Parameters

  - `event_map` - A TransactionEventMap struct with action and payload data

  ## Returns

  - `success_tuple()` - Processing succeeded, entity and event are created normally with EventQueueItem status `:processed`
  - `error_tuple()` - Processing failed, returns validation changeset or error atom without EventQueueItem persistence

  ## Examples

      iex> # Valid event processes successfully
      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, revenue_account} = DoubleEntryLedger.AccountStore.create(%{name: "Revenue", type: :liability, currency: :USD, instance_id: instance.id})
      iex> {:ok, cash_account} = DoubleEntryLedger.AccountStore.create(%{name: "Cash", type: :asset, currency: :USD, instance_id: instance.id})
      iex> valid_event = %TransactionEventMap{action: :create_transaction,
      ...>   instance_id: instance.id,
      ...>   source: "admin_panel",
      ...>   source_idempk: "acc_create_456",
      ...>   payload: %{
      ...>      status: :pending,
      ...>      entries: [
      ...>        %{account_id: revenue_account.id, amount: 100, currency: :USD},
      ...>        %{account_id: cash_account.id, amount: 100, currency: :USD}
      ...>      ]
      ...>   }}
      iex> {:ok, _transaction, event} = EventWorker.process_new_event_no_save_on_error(valid_event)
      iex> event.event_queue_item.status
      :processed

      # Create a new account
      iex> alias DoubleEntryLedger.Event.{AccountEventMap, AccountData}
      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> event_map = %AccountEventMap{
      ...>   action: :create_account,
      ...>   instance_id: instance.id,
      ...>   source: "admin_panel",
      ...>   source_idempk: "acc_create_456",
      ...>   payload: %AccountData{
      ...>     name: "Petty Cash",
      ...>     type: :asset,
      ...>     currency: "USD"
      ...>   }
      ...> }
      iex> {:ok, account, event} = EventWorker.process_new_event_no_save_on_error(event_map)
      iex> account.name
      "Petty Cash"
      iex> event.event_queue_item.status
      :processed

      iex> # Unsupported action
      iex> unsupported = %TransactionEventMap{action: :invalid_action}
      iex> EventWorker.process_new_event_no_save_on_error(unsupported)
      {:error, :action_not_supported}

  ## Use Cases

      # Validate before committing to standard processing
      case EventWorker.process_new_event_no_save_on_error(event_map) do
        {:ok, _, _} ->
          # Safe to process normally
          EventWorker.process_new_event(event_map)
        {:error, changeset} ->
          # Handle validation errors without EventQueueItem pollution
          {:error, format_validation_errors(changeset)}
      end
  """
  @spec process_new_event_no_save_on_error(em) ::
          success_tuple() | {:error, Changeset.t(em) | String.t()}
        when em: TransactionEventMap.t() | AccountEventMap.t()
  def process_new_event_no_save_on_error(
        %TransactionEventMap{action: :create_transaction} = event_map
      ) do
    CreateTransactionEventMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(
        %TransactionEventMap{action: :update_transaction} = event_map
      ) do
    UpdateTransactionEventMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(%AccountEventMap{action: :create_account} = event_map) do
    CreateAccountEventMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(%AccountEventMap{action: :update_account} = event_map) do
    UpdateAccountEventMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(_event_map), do: {:error, :action_not_supported}

  @doc """
  Retrieves and processes an existing event by its UUID using atomic EventQueueItem claiming.

  This function enables processing of events that were previously stored in the database
  but not yet processed. It implements an atomic claim-and-process pattern through the
  EventQueueItem to ensure that only one processor can work on an event at a time,
  preventing race conditions and duplicate processing in concurrent environments.

  ## EventQueueItem Claiming Process

  1. **Atomic Claim** - Updates EventQueueItem status from `:pending` or claimable error states to `:processing`
  2. **Processor Assignment** - Records processor_id and processing_started_at timestamp in EventQueueItem
  3. **Optimistic Locking** - Uses processor_version for concurrent update protection
  4. **Processing** - Delegates to appropriate handler based on action
  5. **Completion** - Updates EventQueueItem status to `:processed` or appropriate error state

  ## Use Cases

  - **Retry Processing** - Reprocess events that failed previously (EventQueueItem status `:failed` or `:occ_timeout`)
  - **Manual Processing** - Admin tools for processing specific events
  - **Batch Processing** - Process queued events in background jobs
  - **Event Replay** - Reprocess events for audit or recovery scenarios

  ## Parameters

  - `uuid` - String UUID of the event to process
  - `processor_id` - Optional identifier for the processor (defaults to "manual")
    Recorded in EventQueueItem for tracking which system/user initiated the processing

  ## Returns

  - `success_tuple()` - Event was claimed and processed successfully, EventQueueItem status `:processed`
  - `{:error, :event_not_found}` - No event exists with the provided UUID
  - `{:error, :event_already_claimed}` - Another processor is already working on this event (EventQueueItem status `:processing`)
  - `{:error, :event_not_claimable}` - Event is in a non-processable state (e.g., already `:processed`)
  - `error_tuple()` - Processing failed after successful claim, EventQueueItem updated to appropriate error state

  ## EventQueueItem States and Claimability

  | EventQueueItem Status | Claimable? | Description |
  |-------------|------------|-------------|
  | `:pending` | ✓ | Ready for initial processing |
  | `:failed` | ✓ | Failed previously, can be retried (if retry window passed) |
  | `:occ_timeout` | ✓ | Failed due to optimistic concurrency, can be retried |
  | `:processing` | ✗ | Currently being processed by another worker |
  | `:processed` | ✗ | Successfully completed |
  | `:dead_letter` | ✗ | Permanently failed after exhausting retries |

  ## Examples

      # Process a pending event
      {:ok, transaction, event} = EventWorker.process_event_with_id("550e8400-e29b-41d4-a716-446655440000")
      event.event_queue_item.status
      :processed
      event.event_queue_item.processor_id
      "manual"

      # Attempt to process non-existent event
      EventWorker.process_event_with_id("00000000-0000-0000-0000-000000000000")
      {:error, :event_not_found}

      # Process with custom processor ID
      {:ok, _, event} = EventWorker.process_event_with_id(event_uuid, "background_job_1")
      event.event_queue_item.processor_id
      "background_job_1"

      # Event already being processed
      Task.async(fn -> EventWorker.process_event_with_id(uuid, "proc_1") end)
      EventWorker.process_event_with_id(uuid, "proc_2")
      {:error, :event_already_claimed}

      # Retry a failed event
      {:ok, _, event} = EventWorker.process_event_with_id(failed_event_uuid)
      event.event_queue_item.status
      :processed
      event.event_queue_item.retry_count
      2

  ## Concurrency Safety

  The claiming mechanism uses database-level optimistic locking on EventQueueItem to ensure atomicity:
  This prevents race conditions even with multiple concurrent processors.

  ## Monitoring and Debugging

  The processor_id and timing fields in EventQueueItem help with operational monitoring:

  - Track which systems are processing events (`processor_id`)
  - Debug stuck or slow processing jobs through EventQueueItem queries
  - Implement processor-specific retry logic (`retry_count`, `occ_retry_count`)
  - Generate processing performance metrics from EventQueueItem timestamps
  - Monitor error patterns through the `errors` array
  """
  @spec process_event_with_id(Ecto.UUID.t(), String.t()) ::
          success_tuple() | error_tuple()
  def process_event_with_id(uuid, processor_id \\ "manual") do
    case claim_event_for_processing(uuid, processor_id) do
      {:ok, event} -> process_event(event)
      {:error, error} -> {:error, error}
    end
  end

  # Private function - processes a claimed event based on its action type
  @spec process_event(Event.t()) :: success_tuple() | error_tuple()
  defp process_event(
         %Event{event_queue_item: %{status: :processing}, action: :create_transaction} = event
       ) do
    CreateTransactionEvent.process(event)
  end

  defp process_event(
         %Event{event_queue_item: %{status: :processing}, action: :update_transaction} = event
       ) do
    UpdateTransactionEvent.process(event)
  end

  defp process_event(%Event{event_queue_item: %{status: :processing}, action: _} = _event) do
    {:error, :action_not_supported}
  end

  defp process_event(%Event{} = _event), do: {:error, :event_not_in_processing_state}
end
