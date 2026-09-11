defmodule DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMap do
  @moduledoc """
  Processes `TransactionCommandMap` structures for atomic creation of commands and
  their associated transactions in the Double Entry Ledger system.

  This module implements the Optimistic Concurrency Control (OCC) pattern to ensure
  safe concurrent processing of events, providing robust error handling, retry logic,
  and transactional guarantees. It handles `:create_transaction` only,
  ensuring that all operations are performed atomically and consistently.

  ## Features

    * Transaction Processing: Creates the transaction described by the command map.
    * Atomic Operations: Ensures all command and transaction changes are performed in a single database transaction.
    * Error Handling: Validation and transformation failures return a changeset and
      persist nothing.
    * Retry Logic: Retries OCC conflicts. This path has no dependency to resolve, so
      nothing is scheduled for a dependency error.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent command processing.
  ## Main Functions

    * `process/2` — Entry point for processing command maps with error handling and OCC.
    * `build_transaction/4` — Constructs Ecto.Multi operations for `:create_transaction`.
    * `handle_build_transaction/3` — Adds the `:command_success` step, plus the
      pending-transaction lookup for a `:pending` transaction.

  This module combines atomic writes, OCC, and idempotency checks so concurrent retries do not
  duplicate the underlying business operation.
  """
  use DoubleEntryLedger.Occ.Processor
  use DoubleEntryLedger.Logger

  alias DoubleEntryLedger.{Command, JournalEvent, PendingTransactionLookup}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Stores.{CommandStoreHelper, TransactionStoreHelper}

  alias Ecto.Multi

  import DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    only: [default_response_handler: 2]

  import DoubleEntryLedger.CommandQueue.Scheduling

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
    as: :handle_transaction_map_error,
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler

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
    as: :handle_occ_final_timeout,
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionCommandResponseHandler

  @doc """
  Processes an `TransactionCommandMap` by creating both a command record and its associated transaction atomically.

  This function is designed for synchronous use, ensuring that both the command and the transaction
  are created in one atomic operation. It handles `:create_transaction` only; a command map
  carrying any other action raises `FunctionClauseError`. The entire operation uses Optimistic
  Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively.

  ## Parameters

    - `command_map`: An `TransactionCommandMap` struct containing all command and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, command}` on success. The third element is the processed
      `Command`; its `command_queue_item` carries the resulting status.
    - `{:error, command}` when OCC retries are exhausted: the returned `Command` is
      left in `:occ_timeout` and can be retried.
    - `{:error, changeset}` if validation errors occur:
      - For command validation failures, the TransactionCommandMap changeset will contain command-related errors.
      - For transaction validation failures, the TransactionCommandMap changeset will contain mapped transaction errors.
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(TransactionCommandMap.t(), Ecto.Repo.t() | nil) ::
          CommandWorker.success_tuple() | CommandWorker.error_tuple()
  def process(%{action: :create_transaction} = command_map, repo \\ Repo) do
    case process_with_retry(command_map, repo) do
      {:ok, %{command_failure: event}} ->
        persisted_failure(event)

      response ->
        default_response_handler(response, command_map)
    end
  end

  @impl true
  @doc """
  Builds an `Ecto.Multi` for a `:create_transaction` command map.

  Inserts the command with status `:pending`, creates the transaction in the ledger,
  and marks the command processed with the transaction id.

  ## Parameters

    - `command_map`: An `TransactionCommandMap` struct containing the command details and action type.
    - `transaction_map`: A map containing the transaction data to be created.
    - `instance_id`: UUID of the ledger instance.
    - `repo`: The Ecto repository to use for database operations.

  ## Returns

    - An `Ecto.Multi` struct containing the operations to execute within a transaction.
  """
  def build_transaction(
        %{action: :create_transaction} = command_map,
        transaction_map,
        instance_id,
        repo
      ) do
    new_command_map = Map.put_new(command_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:new_command, fn _ ->
      CommandStoreHelper.build_create(new_command_map, instance_id)
    end)
    |> TransactionStoreHelper.build_create(:transaction, transaction_map, repo)
    |> Multi.insert(:journal_event, fn %{
                                         new_command: %{id: cid, command_map: em},
                                         transaction: %{id: tid}
                                       } ->
      JournalEvent.build_create(%{
        command_map: em,
        instance_id: instance_id,
        command_id: cid,
        transaction_id: tid
      })
    end)
  end

  @impl true
  @doc """
  Adds the step that marks the command processed once the transaction is written.

  Both clauses only handle success — this module has no dependency to resolve, so
  there is no failure branch. For a `:pending` transaction the multi also inserts a
  `PendingTransactionLookup` row so a later update command can find the transaction.

  ## Parameters

    - `multi`: The `Ecto.Multi` built so far.
    - `command_map`: The command map being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with a `:command_success` step.
  """
  def handle_build_transaction(multi, %{payload: %{status: :pending}} = command_map, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: %{id: tid}, new_command: %{id: cid} = command, journal_event: %{id: jid}} ->
        Multi.update(Multi.new(), :command_success, fn _ ->
          build_mark_as_processed(command)
        end)
        |> Multi.insert(:pending_transaction_lookup, fn _ ->
          attrs = %{
            command_id: cid,
            source: command_map.source,
            source_idempk: command_map.source_idempk,
            instance_id: command.instance_id,
            transaction_id: tid,
            journal_event_id: jid
          }

          PendingTransactionLookup.upsert_changeset(%PendingTransactionLookup{}, attrs)
        end)
    end)
  end

  def handle_build_transaction(multi, _command_map, _repo) do
    multi
    |> Multi.merge(fn
      %{new_command: %{id: _cid} = command} ->
        Multi.update(Multi.new(), :command_success, fn _ ->
          build_mark_as_processed(command)
        end)
    end)
  end
end
