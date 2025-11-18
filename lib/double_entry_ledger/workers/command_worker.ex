defmodule DoubleEntryLedger.Workers.CommandWorker do
  @moduledoc """
  Main event processing orchestrator for the Double Entry Ledger system.

  This module serves as the primary interface for processing accounting events that create
  and update double-entry ledger transactions and accounts. It coordinates between different
  processing strategies and delegates to specialized handler modules based on event types
  and actions.

  ## Processing Strategies

  The CommandWorker supports multiple processing approaches:

  1. **New Command Maps** (`process_new_event/1`) - Direct processing of event maps from external systems. Command is saved for retry later if it fails.
  2. **No-Save-On-Error** (`process_new_event_no_save_on_error/1`) - Processing as above without saving the Command.
  3. **Stored Events** (`process_event_with_id/2`) - Processing events already in the database using atomic claiming

  ## Supported Command Types and Actions

  ### TransactionCommandMap
  - `:create_transaction` - Creates new double-entry transactions with balanced entries
  - `:update_transaction` - Updates pending transactions only

  ### AccountCommandMap
  - `:create_account` - Creates new ledger accounts with specified types and currencies
  - `:update_account` - Updates existing account properties

  ## Command Processing Flow

  ### Direct processing of event maps
  ```
  External System → EventMap → CommandWorker → Specialized Handler → Transaction/Account
                                    ↓
                                  Command → CommandQueueItem → Final State
                                                ↓
                                            Retryable State
  ```

  ### Stored event
  ```
  EventQueue → Command → CommandWorker → Specialized Handler → Transaction/Account
                          ↓
                      CommandQueueItem → Final State
                          ↓
                       Retryable State
  ```

  ## CommandQueueItem State Management

  Events are tracked through `CommandQueueItem` records that maintain processing state:

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

  - **Standard Processing**: Errors update CommandQueueItem status and error details for retry logic
  - **No-Save-On-Error**: Validation errors return changesets without Command and CommandQueueItem persistence
  - **Command Claiming**: Uses optimistic locking on CommandQueueItem to prevent concurrent processing
  - **Retry Logic**: Failed events can be automatically retried based on CommandQueueItem configuration

  ## Handler Modules

  The CommandWorker delegates to specialized handlers in the `DoubleEntryLedger.Workers.CommandWorker` namespace:

  - `CreateTransactionCommandMap` - New transaction creation from event maps
  - `UpdateTransactionCommandMap` - Transaction updates from event maps
  - `CreateTransactionEvent` - Transaction creation from stored events
  - `UpdateTransactionEvent` - Transaction updates from stored events
  - `CreateTransactionCommandMapNoSaveOnError` - Transaction creation without error persistence
  - `UpdateTransactionCommandMapNoSaveOnError` - Transaction updates without error persistence
  - `CreateAccountCommandMapNoSaveOnError` - Account creation without error persistence
  - `UpdateAccountCommandMapNoSaveOnError` - Account updates without error persistence

  ## Examples

      # Process a new transaction event
      event_map = %TransactionCommandMap{
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

      {:ok, transaction, event} = CommandWorker.process_new_event(event_map)
      # event.command_queue_item.status == :processed

      # Process an existing event by ID
      {:ok, transaction, event} = CommandWorker.process_event_with_id(event_uuid)

      # Process without saving errors to CommandQueueItem
      {:ok, transaction, event} = CommandWorker.process_new_event_no_save_on_error(event_map)

  ## Architecture Notes

  - All processing maintains ACID properties through database transactions
  - Events are claimed atomically via CommandQueueItem to prevent duplicate processing
  - Double-entry rules are enforced: debits must equal credits
  - Processing is idempotent based on source identifiers
  - Retry logic and error tracking handled through CommandQueueItem state management
  """
  alias DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommandMapNoSaveOnError
  alias Ecto.Changeset

  alias DoubleEntryLedger.{
    Command,
    Transaction,
    Account
  }

  alias DoubleEntryLedger.Command.{TransactionCommandMap, AccountCommandMap}

  alias DoubleEntryLedger.Workers.CommandWorker.{
    CreateAccountCommand,
    CreateTransactionEvent,
    UpdateAccountCommand,
    UpdateTransactionEvent,
    CreateTransactionCommandMap,
    UpdateTransactionCommandMap,
    CreateAccountCommandMapNoSaveOnError,
    UpdateAccountCommandMapNoSaveOnError,
    CreateTransactionCommandMapNoSaveOnError,
    UpdateTransactionCommandMapNoSaveOnError
  }

  import DoubleEntryLedger.CommandQueue.Scheduling, only: [claim_event_for_processing: 2]

  @typedoc """
  Success result from event processing operations.

  Contains the created or updated domain entity (Transaction or Account) along with
  the final Command record that tracks the processing state. The associated CommandQueueItem
  will have status `:processed` upon successful completion.

  ## Fields

  - First element: The created/updated domain entity (`Transaction.t()` or `Account.t()`)
  - Second element: The `Command.t()` record with processing metadata and associated CommandQueueItem

  ## CommandQueueItem State on Success

  Upon success, the Command's CommandQueueItem will have:
  - `status: :processed` - Indicates successful completion
  - `processing_completed_at: DateTime` - Timestamp of completion
  - `processor_id: String` - Identifier of the processing system
  - `errors: []` - No error information

  ## Examples

      {:ok, %Transaction{id: "123", status: :pending},
           %Command{command_queue_item: %{status: :processed, processing_completed_at: ~U[...]}}}

      {:ok, %Account{name: "Cash"},
           %Command{command_queue_item: %{status: :processed, processor_id: "api_worker"}}}
  """
  @type success_tuple :: {:ok, Transaction.t() | Account.t(), Command.t()}

  @typedoc """
  Error result from event processing operations.

  Represents various failure modes that can occur during event processing. The error
  content provides context about what went wrong and can be used for debugging,
  retry logic, or user feedback.

  ## Error Types

  - `Command.t()` - Processing failed after the event was created/updated. The Command's
    CommandQueueItem will have status `:failed`, `:occ_timeout`, or `:dead_letter` based
    on the error type and retry configuration
  - `Changeset.t()` - Validation failed with detailed field-level error information
  - `String.t()` - General error with a descriptive message
  - `atom()` - Specific error codes like `:event_not_found` or `:action_not_supported`

  ## CommandQueueItem Error States

  When processing fails with an Command error, the CommandQueueItem may have:
  - `status: :failed` - Temporary failure, will be retried
  - `status: :occ_timeout` - Optimistic concurrency timeout, will be retried
  - `status: :dead_letter` - Permanent failure after exhausting retries
  - `errors: [%{...}]` - Array of error details with timestamps
  - `next_retry_after: DateTime` - When the next retry attempt should occur (for `:failed` status)

  ## Examples

      {:error, %Command{command_queue_item: %{status: :failed, errors: [%{message: "Insufficient balance"}]}}}
      {:error, %Changeset{errors: [amount: {"must be positive", []}]}}
      {:error, "Database connection failed"}
      {:error, :action_not_supported}
  """
  @type error_tuple :: {:error, Command.t() | Changeset.t() | String.t() | atom()}

  @doc """
  Processes a new event map by dispatching to the appropriate specialized handler.

  This is the primary entry point for processing events received from external systems.
  The function examines the event map's action and type to route it to the correct
  processing module. Each handler is responsible for validation, transformation, and
  persistence of the event and its resulting domain entities.

  ## Command Processing Flow

  1. **Command Creation** - Creates Command record and associated CommandQueueItem with status `:pending`
  2. **Status Update** - Updates CommandQueueItem to `:processing` during processing
  3. **Validation** - Ensures event map structure and data integrity
  4. **Transformation** - Converts event data into domain entities
  5. **Persistence** - Saves entities and updates CommandQueueItem to `:processed`
  6. **Error Handling** - Updates CommandQueueItem to appropriate error status (`:failed`, `:occ_timeout`, `:dead_letter`)

  ## Parameters

  - `event_map` - A validated event map struct with the following key fields:
    - `:action` - The operation type (`:create_transaction`, `:update_transaction`, `:create_account`, `:update_account`)
    - `:instance_id` - UUID of the ledger instance
    - `:source` - External system identifier
    - `:source_idempk` - Idempotency key from source system
    - `:payload` - Command-specific data for processing

  ## Returns

  - `success_tuple()` - Processing succeeded, returns the created entity and event with CommandQueueItem status `:processed`
  - `error_tuple()` - Processing failed, returns error details and CommandQueueItem in appropriate error state

  ## Supported Actions

  ### Transaction Events
  - `:create_transaction` - Creates new double-entry transactions with balanced entries
  - `:update_transaction` - Modifies existing transactions (status, metadata, etc.)

  ### Account Events
  - `:create_account` - Creates new ledger accounts with specified types and currencies
  - `:update_account` - Updates existing account properties

  ## Examples

      # Create a new transaction
      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> alias DoubleEntryLedger.Command.{TransactionCommandMap, TransactionData}
      iex> {:ok, instance} = InstanceStore.create(%{address: "instance1"})
      iex> {:ok, revenue_account} = AccountStore.create(instance.address, %{address: "account:revenue", type: :liability, currency: :USD}, "unique_id_123")
      iex> {:ok, cash_account} = AccountStore.create(instance.address, %{address: "account:cash", type: :asset, currency: :USD}, "unique_id_456")
      iex> event_map = %TransactionCommandMap{
      ...>   action: :create_transaction,
      ...>   instance_address: instance.address,
      ...>   source: "payment_api",
      ...>   source_idempk: "payment_123",
      ...>   payload: %TransactionData{
      ...>     status: :pending,
      ...>     entries: [
      ...>       %{account_address: cash_account.address, amount: 100, currency: "USD"},
      ...>       %{account_address: revenue_account.address, amount: 100, currency: "USD"}
      ...>     ]
      ...>   }
      ...> }
      iex> {:ok, transaction, event} = CommandWorker.process_new_event(event_map)
      iex> { transaction.status, event.command_queue_item.status }
      {:pending, :processed}

      # Unsupported action
      iex> invalid_map = %TransactionCommandMap{action: :delete_transaction}
      iex> CommandWorker.process_new_event(invalid_map)
      {:error, :action_not_supported}

  ## Error Scenarios

      # Validation failure (returns changeset)
      {:error, %Changeset{errors: [amount: {"must be positive", []}]}}

      # Business rule violation (returns event with error in CommandQueueItem)
      {:error, %Command{command_queue_item: %{status: :failed, errors: [%{message: "Debit and credit amounts must balance"}]}}}

      # Optimistic concurrency timeout
      {:error, %Command{command_queue_item: %{status: :occ_timeout, next_retry_after: ~U[...]}}}

      # System error
      {:error, "Database connection timeout"}
  """
  @spec process_new_event(TransactionCommandMap.t()) ::
          success_tuple() | error_tuple()
  def process_new_event(%TransactionCommandMap{action: :create_transaction} = event_map) do
    CreateTransactionCommandMap.process(event_map)
  end

  def process_new_event(%TransactionCommandMap{action: :update_transaction} = event_map) do
    UpdateTransactionCommandMap.process(event_map)
  end

  def process_new_event(_event_map), do: {:error, :action_not_supported}

  @doc """
  Processes an event map without persisting processing errors to the CommandQueueItem.

  This function provides an alternative processing strategy for scenarios where you want
  to validate and process events but avoid storing error states in the CommandQueueItem records.
  This is useful for:

  - **Validation Testing** - Check if an event would process successfully without side effects
  - **Batch Processing** - Process multiple events and handle errors in memory
  - **Preview Mode** - Show users what would happen without committing changes
  - **Error Recovery** - Retry processing without accumulating error history in CommandQueueItem

  ## Key Differences from Standard Processing

  - **Error Persistence**: Validation errors return changesets instead of creating CommandQueueItem error records
  - **Rollback Behavior**: Failed processing leaves no database traces
  - **Performance**: Slightly faster due to reduced database writes on errors
  - **State Management**: No CommandQueueItem status transitions for validation failures

  ## CommandQueueItem Behavior

  - **Success**: CommandQueueItem created with status `:processed` (same as standard processing)
  - **Validation Errors**: No CommandQueueItem created, changeset returned directly
  - **System Errors**: No CommandQueueItem error state persisted

  ## Parameters

  - `event_map` - A TransactionCommandMap struct with action and payload data

  ## Returns

  - `success_tuple()` - Processing succeeded, entity and event are created normally with CommandQueueItem status `:processed`
  - `error_tuple()` - Processing failed, returns validation changeset or error atom without CommandQueueItem persistence

  ## Examples

      iex> # Valid event processes successfully
      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> alias DoubleEntryLedger.Command.{TransactionCommandMap, TransactionData}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, revenue_account} = AccountStore.create(instance.address, %{address: "account:revenue", type: :liability, currency: :USD}, "unique_id_123")
      iex> {:ok, cash_account} = AccountStore.create(instance.address, %{address: "account:cash", type: :asset, currency: :USD}, "unique_id_456")
      iex> valid_event = %TransactionCommandMap{action: :create_transaction,
      ...>   instance_address: instance.address,
      ...>   source: "admin_panel",
      ...>   source_idempk: "acc_create_456",
      ...>   payload: %TransactionData{
      ...>      status: :pending,
      ...>      entries: [
      ...>        %{account_address: revenue_account.address, amount: 100, currency: :USD},
      ...>        %{account_address: cash_account.address, amount: 100, currency: :USD}
      ...>      ]
      ...>   }}
      iex> {:ok, _transaction, event} = CommandWorker.process_new_event_no_save_on_error(valid_event)
      iex> event.command_queue_item.status
      :processed

      # Create a new account
      iex> alias DoubleEntryLedger.Command.{AccountCommandMap, AccountData}
      iex> {:ok, instance} = DoubleEntryLedger.Stores.InstanceStore.create(%{address: "Sample:Instance"})
      iex> event_map = %AccountCommandMap{
      ...>   action: :create_account,
      ...>   instance_address: instance.address,
      ...>   source: "admin_panel",
      ...>   payload: %AccountData{
      ...>     name: "Petty Cash",
      ...>     address: "account:petty_cash",
      ...>     type: :asset,
      ...>     currency: "USD"
      ...>   }
      ...> }
      iex> {:ok, account, event} = CommandWorker.process_new_event_no_save_on_error(event_map)
      iex> account.name
      "Petty Cash"
      iex> event.command_queue_item.status
      :processed

      iex> # Unsupported action
      iex> unsupported = %TransactionCommandMap{action: :invalid_action}
      iex> CommandWorker.process_new_event_no_save_on_error(unsupported)
      {:error, :action_not_supported}

  ## Use Cases

      # Validate before committing to standard processing
      case CommandWorker.process_new_event_no_save_on_error(event_map) do
        {:ok, _, _} ->
          # Safe to process normally
          CommandWorker.process_new_event(event_map)
        {:error, changeset} ->
          # Handle validation errors without CommandQueueItem pollution
          {:error, format_validation_errors(changeset)}
      end
  """
  @spec process_new_event_no_save_on_error(em) ::
          success_tuple() | {:error, Changeset.t(em) | String.t()}
        when em: TransactionCommandMap.t() | AccountCommandMap.t()
  def process_new_event_no_save_on_error(
        %TransactionCommandMap{action: :create_transaction} = event_map
      ) do
    CreateTransactionCommandMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(
        %TransactionCommandMap{action: :update_transaction} = event_map
      ) do
    UpdateTransactionCommandMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(%AccountCommandMap{action: :create_account} = event_map) do
    CreateAccountCommandMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(%AccountCommandMap{action: :update_account} = event_map) do
    UpdateAccountCommandMapNoSaveOnError.process(event_map)
  end

  def process_new_event_no_save_on_error(_event_map), do: {:error, :action_not_supported}

  @doc """
  Retrieves and processes an existing event by its UUID using atomic CommandQueueItem claiming.

  This function enables processing of events that were previously stored in the database
  but not yet processed. It implements an atomic claim-and-process pattern through the
  CommandQueueItem to ensure that only one processor can work on an event at a time,
  preventing race conditions and duplicate processing in concurrent environments.

  ## CommandQueueItem Claiming Process

  1. **Atomic Claim** - Updates CommandQueueItem status from `:pending` or claimable error states to `:processing`
  2. **Processor Assignment** - Records processor_id and processing_started_at timestamp in CommandQueueItem
  3. **Optimistic Locking** - Uses processor_version for concurrent update protection
  4. **Processing** - Delegates to appropriate handler based on action
  5. **Completion** - Updates CommandQueueItem status to `:processed` or appropriate error state

  ## Use Cases

  - **Retry Processing** - Reprocess events that failed previously (CommandQueueItem status `:failed` or `:occ_timeout`)
  - **Manual Processing** - Admin tools for processing specific events
  - **Batch Processing** - Process queued events in background jobs
  - **Command Replay** - Reprocess events for audit or recovery scenarios

  ## Parameters

  - `uuid` - String UUID of the event to process
  - `processor_id` - Optional identifier for the processor (defaults to "manual")
    Recorded in CommandQueueItem for tracking which system/user initiated the processing

  ## Returns

  - `success_tuple()` - Command was claimed and processed successfully, CommandQueueItem status `:processed`
  - `{:error, :event_not_found}` - No event exists with the provided UUID
  - `{:error, :event_already_claimed}` - Another processor is already working on this event (CommandQueueItem status `:processing`)
  - `{:error, :event_not_claimable}` - Command is in a non-processable state (e.g., already `:processed`)
  - `error_tuple()` - Processing failed after successful claim, CommandQueueItem updated to appropriate error state

  ## CommandQueueItem States and Claimability

  | CommandQueueItem Status | Claimable? | Description |
  |-------------|------------|-------------|
  | `:pending` | ✓ | Ready for initial processing |
  | `:failed` | ✓ | Failed previously, can be retried (if retry window passed) |
  | `:occ_timeout` | ✓ | Failed due to optimistic concurrency, can be retried |
  | `:processing` | ✗ | Currently being processed by another worker |
  | `:processed` | ✗ | Successfully completed |
  | `:dead_letter` | ✗ | Permanently failed after exhausting retries |

  ## Examples

      # Process a pending event
      {:ok, transaction, event} = CommandWorker.process_event_with_id("550e8400-e29b-41d4-a716-446655440000")
      event.command_queue_item.status
      :processed
      event.command_queue_item.processor_id
      "manual"

      # Attempt to process non-existent event
      CommandWorker.process_event_with_id("00000000-0000-0000-0000-000000000000")
      {:error, :event_not_found}

      # Process with custom processor ID
      {:ok, _, event} = CommandWorker.process_event_with_id(event_uuid, "background_job_1")
      event.command_queue_item.processor_id
      "background_job_1"

      # Command already being processed
      Task.async(fn -> CommandWorker.process_event_with_id(uuid, "proc_1") end)
      CommandWorker.process_event_with_id(uuid, "proc_2")
      {:error, :event_already_claimed}

      # Retry a failed event
      {:ok, _, event} = CommandWorker.process_event_with_id(failed_event_uuid)
      event.command_queue_item.status
      :processed
      event.command_queue_item.retry_count
      2

  ## Concurrency Safety

  The claiming mechanism uses database-level optimistic locking on CommandQueueItem to ensure atomicity:
  This prevents race conditions even with multiple concurrent processors.

  ## Monitoring and Debugging

  The processor_id and timing fields in CommandQueueItem help with operational monitoring:

  - Track which systems are processing events (`processor_id`)
  - Debug stuck or slow processing jobs through CommandQueueItem queries
  - Implement processor-specific retry logic (`retry_count`, `occ_retry_count`)
  - Generate processing performance metrics from CommandQueueItem timestamps
  - Monitor error patterns through the `errors` array
  """
  @spec process_event_with_id(Ecto.UUID.t(), String.t()) ::
          success_tuple() | error_tuple()
  def process_event_with_id(uuid, processor_id \\ "manual") do
    case claim_event_for_processing(uuid, processor_id) do
      {:ok, event} ->
        process_event(event)

      {:error, error} ->
        {:error, error}
    end
  end

  # Private function - processes a claimed event based on its action type
  @spec process_event(Command.t()) :: success_tuple() | error_tuple()
  defp process_event(
         %Command{
           command_queue_item: %{status: :processing},
           event_map: %{action: :create_transaction}
         } = event
       ) do
    CreateTransactionEvent.process(event)
  end

  defp process_event(
         %Command{
           command_queue_item: %{status: :processing},
           event_map: %{"action" => "create_transaction"}
         } = event
       ) do
    CreateTransactionEvent.process(event)
  end

  defp process_event(
         %Command{
           command_queue_item: %{status: :processing},
           event_map: %{action: :update_transaction}
         } = event
       ) do
    UpdateTransactionEvent.process(event)
  end

  defp process_event(
         %Command{
           command_queue_item: %{status: :processing},
           event_map: %{"action" => "update_transaction"}
         } = event
       ) do
    UpdateTransactionEvent.process(event)
  end

  defp process_event(
         %Command{
           command_queue_item: %{status: :processing},
           event_map: %{action: :create_account}
         } =
           event
       ) do
    CreateAccountCommand.process(event)
  end

  defp process_event(
         %Command{
           command_queue_item: %{status: :processing},
           event_map: %{action: :update_account}
         } =
           event
       ) do
    UpdateAccountCommand.process(event)
  end

  defp process_event(%Command{command_queue_item: %{status: :processing}}) do
    {:error, :action_not_supported}
  end

  defp process_event(%Command{} = _event), do: {:error, :event_not_in_processing_state}
end
