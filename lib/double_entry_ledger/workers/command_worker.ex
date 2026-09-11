defmodule DoubleEntryLedger.Workers.CommandWorker do
  @moduledoc """
  Main command processing orchestrator for the Double Entry Ledger system.

  Routes an accounting command to the specialized handler for its type and
  action, and records the outcome on the command's `CommandQueueItem`.

  ## Public functions

  1. `process_new_command/1` - processes a command map from an external system.
     A retryable failure, such as an OCC timeout, persists the command so it can
     be retried later; a validation or transformation failure returns a changeset
     and persists nothing.
  2. `process_new_command_no_save_on_error/1` - the same, except nothing is
     persisted for any failure.
  3. `process_command_with_id/2` - claims a command already stored in the
     database and processes it.

  ## Supported actions

  - `:create_transaction`, `:update_transaction` on a `TransactionCommandMap`
  - `:create_account`, `:update_account` on an `AccountCommandMap`

  ## CommandQueueItem status lifecycle

  This is the lifecycle of a stored command claimed through
  `process_command_with_id/2`.

  The command-map entry points never pass through `:processing`: they insert the
  command and give it its final status in one transaction. That status is
  `:processed` on success, `:occ_timeout` when OCC retries are exhausted, and for
  an update either `:pending`, when the create command it depends on is not yet
  processed, or `:dead_letter` for any other dependency error. A validation or
  transformation failure happens before the insert, so no command is created.

  - `:pending` -> `:processing` -> `:processed` (success)
  - `:pending` -> `:processing` -> `:failed` (retryable error)
  - `:pending` -> `:processing` -> `:occ_timeout` (concurrency timeout, retried)
  - `:pending` -> `:processing` -> `:dead_letter` (permanent failure)
  - `:processing` -> `:pending` when a batch write fails and its commands are
    handed back to the queue (`CommandQueueItem.revert_to_pending_changeset/2`);
    rows left stranded in `:processing` are recovered by `InstanceMonitor` to
    `:failed` or `:dead_letter`.

  ## Error handling

  - **Standard processing**: a retryable error is recorded on the CommandQueueItem;
    a validation or transformation failure returns a changeset and creates no command
  - **No-save-on-error**: no failure is persisted
  - **Command claiming**: a single guarded `UPDATE` whose `WHERE` enforces both
    status and retry deadline; `processor_version` fences the later terminal write
  """
  @behaviour DoubleEntryLedger.Workers.CommandWorkerBehaviour

  alias DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommandMapNoSaveOnError
  alias Ecto.Changeset

  alias DoubleEntryLedger.{
    Command,
    CommandQueueItem,
    Transaction,
    Account,
    Telemetry
  }

  alias DoubleEntryLedger.Command.{TransactionCommandMap, AccountCommandMap}

  alias DoubleEntryLedger.Workers.CommandWorker.{
    CreateAccountCommand,
    CreateTransactionCommand,
    UpdateAccountCommand,
    UpdateTransactionCommand,
    CreateTransactionCommandMap,
    UpdateTransactionCommandMap,
    CreateAccountCommandMapNoSaveOnError,
    UpdateAccountCommandMapNoSaveOnError,
    CreateTransactionCommandMapNoSaveOnError,
    UpdateTransactionCommandMapNoSaveOnError
  }

  import DoubleEntryLedger.CommandQueue.Scheduling, only: [claim_command_for_processing: 2]

  @typedoc """
  Success result from command processing operations.

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

  `processor_id` is set only when a queued command is claimed; the command-map
  entry points leave it `nil`.

  ## Examples

      {:ok, %Transaction{id: "123", status: :pending},
           %Command{command_queue_item: %{status: :processed, processing_completed_at: ~U[...]}}}

      {:ok, %Account{name: "Cash"},
           %Command{command_queue_item: %{status: :processed, processor_id: "api_worker"}}}
  """
  @type success_tuple :: {:ok, Transaction.t() | Account.t(), Command.t()}

  @typedoc """
  Error result from command processing operations.

  Represents various failure modes that can occur during command processing. The error
  content provides context about what went wrong and can be used for debugging,
  retry logic, or user feedback.

  ## Error Types

  - `Command.t()` - Processing failed after the command was created/updated. The Command's
    CommandQueueItem will have status `:failed`, `:occ_timeout`, or `:dead_letter` based
    on the error type and retry configuration
  - `Changeset.t()` - Validation failed with detailed field-level error information
  - `String.t()` - General error with a descriptive message
  - `atom()` - Specific error codes like `:command_not_found` or `:action_not_supported`

  ## CommandQueueItem Error States

  When processing fails with an Command error, the CommandQueueItem may have:
  - `status: :failed` - Temporary failure, will be retried
  - `status: :occ_timeout` - Optimistic concurrency timeout, will be retried
  - `status: :dead_letter` - Permanent failure after exhausting retries
  - `errors: [%{...}]` - Array of error details with timestamps
  - `next_retry_after: DateTime` - When the next retry attempt should occur (set for
    both `:failed` and `:occ_timeout`)

  ## Examples

      {:error, %Command{command_queue_item: %{status: :failed, errors: [%{message: "Insufficient balance"}]}}}
      {:error, %Changeset{errors: [amount: {"must be positive", []}]}}
      {:error, "Database connection failed"}
      {:error, :action_not_supported}
  """
  @type error_tuple :: {:error, Command.t() | Changeset.t() | String.t() | atom()}

  @doc """
  Processes a new command map by dispatching to the appropriate specialized handler.

  This is the primary entry point for processing commands received from external systems.
  The function examines the command map's action and type to route it to the correct
  processing module. Each handler is responsible for validation, transformation, and
  persistence of the command and its resulting domain entities.

  ## Command Processing Flow

  1. **Validation and transformation** - The command map is checked and converted
     into domain entities. A failure here returns a changeset and creates no Command.
  2. **Persistence** - The Command, its CommandQueueItem and the resulting entities
     are written in one transaction, with the CommandQueueItem going straight to
     `:processed`.
  3. **Error handling** - A failure after the insert persists the Command with its
     final status: `:occ_timeout` when OCC retries are exhausted, or for an update
     `:pending` when its create command is not yet processed and `:dead_letter` for
     any other dependency error. `:failed` is not reachable on this path.

  ## Parameters

  - `command_map` - A validated command map struct with the following key fields:
    - `:action` - `:create_transaction` or `:update_transaction`
    - `:instance_address` - Address of the ledger instance
    - `:source` - External system identifier
    - `:source_idempk` - Idempotency key from the source system (transaction commands)
    - `:payload` - Command-specific data for processing

  ## Returns

  - `success_tuple()` - Processing succeeded, returns the created entity and command with CommandQueueItem status `:processed`
  - `error_tuple()` - Processing failed, returns error details and CommandQueueItem in appropriate error state

  ## Supported Actions

  ### Transaction Commands
  - `:create_transaction` - Creates new double-entry transactions with balanced entries
  - `:update_transaction` - Modifies existing transactions (status, metadata, etc.)

  Account actions are not handled here — a `%AccountCommandMap{}` returns
  `{:error, :action_not_supported}`. Use `process_new_command_no_save_on_error/1`
  for `:create_account` and `:update_account`.

  ## Examples

      # Create a new transaction
      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> alias DoubleEntryLedger.Command.{TransactionCommandMap, TransactionData}
      iex> {:ok, instance} = InstanceStore.create(%{address: "instance1"})
      iex> {:ok, revenue_account} = AccountStore.create(instance.address, %{address: "account:revenue", type: :liability, currency: :USD}, "unique_id_123")
      iex> {:ok, cash_account} = AccountStore.create(instance.address, %{address: "account:cash", type: :asset, currency: :USD}, "unique_id_456")
      iex> command_map = %TransactionCommandMap{
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
      iex> {:ok, transaction, command} = CommandWorker.process_new_command(command_map)
      iex> {transaction.status, command.command_queue_item.status}
      {:pending, :processed}

      # Unsupported action
      iex> invalid_map = %TransactionCommandMap{action: :delete_transaction}
      iex> CommandWorker.process_new_command(invalid_map)
      {:error, :action_not_supported}

  ## Error Scenarios

      # Validation failure (returns changeset)
      {:error, %Changeset{errors: [amount: {"must be positive", []}]}}

      # Unbalanced entries: a validation changeset, and the command is rolled back.
      # The error sits on :amount in each entry changeset embedded under :payload.
      {:error,
       %Changeset{
         changes: %{
           payload: %Changeset{
             changes: %{
               entries: [
                 %Changeset{errors: [amount: {"must have equal debit and credit", []}]}
               ]
             }
           }
         }
       }}

      # Optimistic concurrency timeout
      {:error, %Command{command_queue_item: %{status: :occ_timeout, next_retry_after: ~U[...]}}}

      # System error
      {:error, "Database connection timeout"}
  """
  @spec process_new_command(TransactionCommandMap.t()) ::
          success_tuple() | error_tuple()
  def process_new_command(%TransactionCommandMap{action: :create_transaction} = command_map) do
    Telemetry.command_process_span(span_metadata(command_map), fn ->
      CreateTransactionCommandMap.process(command_map)
    end)
  end

  def process_new_command(%TransactionCommandMap{action: :update_transaction} = command_map) do
    Telemetry.command_process_span(span_metadata(command_map), fn ->
      UpdateTransactionCommandMap.process(command_map)
    end)
  end

  def process_new_command(_command_map), do: {:error, :action_not_supported}

  @doc """
  Processes a command map without persisting processing errors to the CommandQueueItem.

  On success this behaves exactly like `process_new_command/1`: the command, its
  CommandQueueItem and the resulting entities are committed. It is **not** a dry
  run or a preview.

  The difference is that failures are not persisted. They come back as a changeset,
  a message string, or `:action_not_supported`, instead of being written to a
  CommandQueueItem. Use it when repeated failures should not accumulate error
  history on the command.

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

  - `command_map` - A `TransactionCommandMap` or `AccountCommandMap` struct with
    action and payload data

  ## Returns

  - `success_tuple()` - Processing succeeded, entity and command are created normally with CommandQueueItem status `:processed`
  - `error_tuple()` - Processing failed, returns validation changeset or error atom without CommandQueueItem persistence

  ## Examples

      iex> # Valid command processes successfully
      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> alias DoubleEntryLedger.Command.{TransactionCommandMap, TransactionData}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, revenue_account} = AccountStore.create(instance.address, %{address: "account:revenue", type: :liability, currency: :USD}, "unique_id_123")
      iex> {:ok, cash_account} = AccountStore.create(instance.address, %{address: "account:cash", type: :asset, currency: :USD}, "unique_id_456")
      iex> valid_command = %TransactionCommandMap{action: :create_transaction,
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
      iex> {:ok, _transaction, command} = CommandWorker.process_new_command_no_save_on_error(valid_command)
      iex> command.command_queue_item.status
      :processed

      # Create a new account
      iex> alias DoubleEntryLedger.Command.{AccountCommandMap, AccountData}
      iex> {:ok, instance} = DoubleEntryLedger.Stores.InstanceStore.create(%{address: "Sample:Instance"})
      iex> command_map = %AccountCommandMap{
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
      iex> {:ok, account, command} = CommandWorker.process_new_command_no_save_on_error(command_map)
      iex> account.name
      "Petty Cash"
      iex> command.command_queue_item.status
      :processed

      iex> # Unsupported action
      iex> unsupported = %TransactionCommandMap{action: :invalid_action}
      iex> CommandWorker.process_new_command_no_save_on_error(unsupported)
      {:error, :action_not_supported}

  """
  @spec process_new_command_no_save_on_error(em) ::
          success_tuple() | {:error, Changeset.t(em) | String.t() | :action_not_supported}
        when em: TransactionCommandMap.t() | AccountCommandMap.t()
  def process_new_command_no_save_on_error(
        %TransactionCommandMap{action: :create_transaction} = command_map
      ) do
    Telemetry.command_process_span(span_metadata(command_map), fn ->
      CreateTransactionCommandMapNoSaveOnError.process(command_map)
    end)
  end

  def process_new_command_no_save_on_error(
        %TransactionCommandMap{action: :update_transaction} = command_map
      ) do
    Telemetry.command_process_span(span_metadata(command_map), fn ->
      UpdateTransactionCommandMapNoSaveOnError.process(command_map)
    end)
  end

  def process_new_command_no_save_on_error(
        %AccountCommandMap{action: :create_account} = command_map
      ) do
    Telemetry.command_process_span(span_metadata(command_map), fn ->
      CreateAccountCommandMapNoSaveOnError.process(command_map)
    end)
  end

  def process_new_command_no_save_on_error(
        %AccountCommandMap{action: :update_account} = command_map
      ) do
    Telemetry.command_process_span(span_metadata(command_map), fn ->
      UpdateAccountCommandMapNoSaveOnError.process(command_map)
    end)
  end

  def process_new_command_no_save_on_error(_command_map), do: {:error, :action_not_supported}

  @doc """
  Claims the command with `uuid` and processes it.

  The claim is a single guarded `UPDATE` whose `WHERE` enforces both the queue
  item's status and its retry deadline, so only one processor can take a command
  and a command is never claimed before its retry time has elapsed. The claim
  advances `processor_version`, invalidating any later write from a previous
  owner.

  ## Parameters

  - `uuid` - UUID of the command to process
  - `processor_id` - Identifier recorded on the queue item (defaults to `"manual"`)

  ## Returns

  - `success_tuple()` - claimed and processed, CommandQueueItem status `:processed`
  - `error_tuple()` - processing failed after the claim, CommandQueueItem in the
    matching error state
  - `{:error, :command_not_found}` - no command exists with that UUID
  - `{:error, :command_already_claimed}` - another processor holds the command
  - `{:error, :command_not_claimable}` - not in a claimable state, or its retry
    deadline has not elapsed
  - `{:error, :command_ownership_lost}` - the claim moved to another processor
    while this one was working, so its write was fenced out
  - `{:error, :command_not_in_processing_state}` - the claimed command was not in
    `:processing`
  - `{:error, :action_not_supported}` - the command's action has no handler

  ## Claimable states

  `:pending`, `:failed` and `:occ_timeout` are claimable once the retry deadline
  has passed; `:processing`, `:processed` and `:dead_letter` are not.
  """
  @impl DoubleEntryLedger.Workers.CommandWorkerBehaviour
  @spec process_command_with_id(Ecto.UUID.t(), String.t()) ::
          success_tuple() | error_tuple()
  def process_command_with_id(uuid, processor_id \\ "manual") do
    case claim_command_for_processing(uuid, processor_id) do
      {:ok, command} ->
        Telemetry.command_process_span(span_metadata(command), fn ->
          process_claimed_command(command)
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp process_claimed_command(command) do
    process_command(command)
  rescue
    error in Ecto.StaleEntryError ->
      case error.changeset.data do
        %CommandQueueItem{} -> {:error, :command_ownership_lost}
        _other -> reraise error, __STACKTRACE__
      end
  end

  # Private function - processes a claimed command based on its action type
  @spec process_command(Command.t()) :: success_tuple() | error_tuple()
  defp process_command(
         %Command{
           command_queue_item: %{status: :processing},
           command_map: %{action: :create_transaction}
         } = command
       ) do
    CreateTransactionCommand.process(command)
  end

  defp process_command(
         %Command{
           command_queue_item: %{status: :processing},
           command_map: %{action: :update_transaction}
         } = command
       ) do
    UpdateTransactionCommand.process(command)
  end

  defp process_command(
         %Command{
           command_queue_item: %{status: :processing},
           command_map: %{action: :create_account}
         } = command
       ) do
    CreateAccountCommand.process(command)
  end

  defp process_command(
         %Command{
           command_queue_item: %{status: :processing},
           command_map: %{action: :update_account}
         } = command
       ) do
    UpdateAccountCommand.process(command)
  end

  defp process_command(%Command{command_queue_item: %{status: :processing}}) do
    {:error, :action_not_supported}
  end

  defp process_command(%Command{} = _command), do: {:error, :command_not_in_processing_state}

  defp span_metadata(%Command{command_map: command_map} = command) do
    %{
      action: Map.get(command_map, :action) || Map.get(command_map, "action"),
      instance_id: command.instance_id,
      source: Map.get(command_map, :source) || Map.get(command_map, "source"),
      trace_context: command.trace_context
    }
  end

  defp span_metadata(%{action: action, source: source, trace_context: trace_context}) do
    %{
      action: action,
      instance_id: nil,
      source: source,
      trace_context: trace_context
    }
  end
end
