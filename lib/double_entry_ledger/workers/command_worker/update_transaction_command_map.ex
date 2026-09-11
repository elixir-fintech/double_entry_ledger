defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMap do
  @moduledoc """
  Processes `TransactionCommandMap` structures for atomic update of events and their associated transactions in the Double Entry Ledger system.

  Implements the Optimistic Concurrency Control (OCC) pattern to ensure safe concurrent processing of update events, providing robust error handling, retry logic, and transactional guarantees. This module ensures that update operations are performed atomically and consistently, and that all error and retry scenarios are handled transparently.

  ## Features

    * Transaction Processing: Handles update of transactions based on the command map's action.
    * Atomic Operations: Ensures all command and transaction changes are performed in a single database transaction.
    * Error Handling: Maps validation and dependency errors to the appropriate changeset or command state.
    * Retry Logic: Retries OCC conflicts. A create command that is not yet processed
      reverts this command to `:pending`; every other dependency error dead-letters it.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent command processing.

  ## Main Functions

    * `process/2` — Entry point for processing update command maps with error handling and OCC.
    * `build_transaction/4` — Constructs Ecto.Multi operations for update actions.
    * `handle_build_transaction/3` — Adds the command update or error handling steps to the Multi.

  Atomic writes, OCC, and idempotency checks make concurrent retries safe without claiming
  stronger delivery semantics than the database-backed queue provides.
  """

  use DoubleEntryLedger.Occ.Processor
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Occ.Helper
  import DoubleEntryLedger.CommandQueue.Scheduling

  import DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    only: [default_response_handler: 2]

  alias DoubleEntryLedger.{Command, JournalEvent}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Stores.{CommandStoreHelper, TransactionStoreHelper}
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError
  alias Ecto.Multi

  @impl true
  @doc """
  Handles errors that occur when converting command map data to a transaction map.

  Delegates to `DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler.handle_transaction_map_error/3`.

  ## Parameters

    - `command_map`: The command map being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` carrying `Multi.error/3` with a `TransactionCommandMap`
      changeset. The transaction rolls back, so no command is created or updated.
  """
  defdelegate handle_transaction_map_error(command_map, error, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    as: :handle_transaction_map_error

  @impl true
  @doc """
  Handles the case when OCC retries are exhausted for a command map.

  Delegates to `DoubleEntryLedger.Workers.CommandWorker.TransactionCommandResponseHandler.handle_occ_final_timeout/2`.

  ## Parameters

    - `command_map`: The command map being processed.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the command as dead letter or timed out.
  """
  defdelegate handle_occ_final_timeout(command_map, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionCommandResponseHandler,
    as: :handle_occ_final_timeout

  @doc """
  Processes an `TransactionCommandMap` by creating both a command record and its associated transaction atomically.

  This function is designed for synchronous use, ensuring that both the command and the transaction
  are updated in one atomic operation. It handles `:update_transaction` only; a command map
  carrying any other action raises `FunctionClauseError`. The entire operation uses Optimistic
  Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively.

  ## Parameters

    - `command_map`: An `TransactionCommandMap` struct containing all command and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, command}` on success. The third element is the processed
      `Command`; its `command_queue_item` carries the resulting status.
    - `{:error, command}` on an OCC or dependency failure. The returned `Command` is
      left in `:occ_timeout` after exhausted retries, in `:pending` when the create
      command it depends on has not been processed yet, or in `:dead_letter` for any
      other dependency error.
    - `{:error, changeset}` if validation errors occur:
      - For command validation failures, the TransactionCommandMap changeset will contain command-related errors.
      - For transaction validation failures, the TransactionCommandMap changeset will contain mapped transaction errors.
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(TransactionCommandMap.t(), Ecto.Repo.t() | nil) ::
          CommandWorker.success_tuple() | CommandWorker.error_tuple()
  def process(%{action: :update_transaction} = command_map, repo \\ Repo) do
    case process_with_retry(command_map, repo) do
      {:ok, %{command_failure: event}} ->
        persisted_failure(event)

      response ->
        default_response_handler(response, command_map)
    end
  end

  @impl true
  @doc """
  Builds an `Ecto.Multi` for an `:update_transaction` command map.

  Inserts the command with status `:pending`, retrieves the transaction created by
  the original create command, updates it with the new data, and marks the command
  processed with the transaction id.

  ## Parameters

    - `command_map`: An `TransactionCommandMap` struct containing the command details and action type.
    - `transaction_map`: A map containing the new transaction data to apply.
    - `instance_id`: UUID of the ledger instance.
    - `repo`: The Ecto repository to use for database operations.

  ## Returns

    - An `Ecto.Multi` struct containing the operations to execute within a transaction.
  """
  def build_transaction(
        %{action: :update_transaction} = command_map,
        transaction_map,
        instance_id,
        repo
      ) do
    new_command_map = Map.put_new(command_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:new_command, fn _ ->
      CommandStoreHelper.build_create(new_command_map, instance_id)
    end)
    |> CommandStoreHelper.build_get_create_transaction_command_transaction(
      :get_create_transaction_command_transaction,
      :new_command
    )
    |> Multi.merge(fn
      %{get_create_transaction_command_transaction: {:error, %UpdateCommandError{} = exception}} ->
        Multi.put(Multi.new(), :get_create_transaction_event_error, exception)

      %{get_create_transaction_command_transaction: create_transaction} ->
        TransactionStoreHelper.build_update(
          Multi.new(),
          :transaction,
          create_transaction,
          transaction_map,
          repo
        )
    end)
  end

  @impl true
  @doc """
  Adds the step to update the command or handle errors after transaction processing.

  This function inspects the results of the previous `Ecto.Multi` steps and determines
  the appropriate next action for the command:

    * If the transaction is written successfully, the command is marked processed.
    * If the create command is not yet processed, the command is reverted to `:pending`.
    * Every other dependency error marks the command `:dead_letter`.

  ## Parameters

    - `multi`: The `Ecto.Multi` built so far.
    - `command_map`: The command map being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with either an `:command_success` or `:command_failure` step.
  """
  def handle_build_transaction(multi, _command_map, _repo) do
    multi
    |> Multi.merge(fn
      %{
        transaction: %{id: tid},
        new_command: %{id: eid, command_map: em, instance_id: iid} = event
      } ->
        Multi.insert(Multi.new(), :journal_event, fn _ ->
          JournalEvent.build_create(%{
            command_map: em,
            instance_id: iid,
            command_id: eid,
            transaction_id: tid
          })
        end)
        |> Multi.update(:command_success, fn _ ->
          build_mark_as_processed(event)
        end)

      %{
        get_create_transaction_event_error: %{reason: :create_command_not_processed} = exception,
        new_command: event
      } ->
        Multi.update(Multi.new(), :command_failure, fn _ ->
          build_revert_to_pending(event, exception.message)
        end)

      %{get_create_transaction_event_error: exception, new_command: event} ->
        Multi.update(Multi.new(), :command_failure, fn _ ->
          build_mark_as_dead_letter(event, exception.message)
        end)
    end)
  end
end
