defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMapNoSaveOnError do
  @moduledoc """
  Processes `TransactionCommandMap` structures for atomic update of commands and their associated transactions in the Double Entry Ledger system, without saving on error.

  Implements the Optimistic Concurrency Control (OCC) pattern to ensure safe concurrent processing of update commands, providing robust error handling, retry logic, and transactional guarantees. This module ensures that update operations are performed atomically and consistently, and that all error and retry scenarios are handled transparently. Unlike the standard update command map processor, this variant does not persist changes on error, but instead returns changesets with error details for client handling.

  ## Features

    * Transaction Processing: Handles update of transactions based on the command map's action.
    * Atomic Operations: Ensures all command and transaction changes are performed in a single database transaction.
    * Error Handling: Maps validation and dependency errors to the appropriate changeset or command state, but does not persist on error.
    * Retry Logic: Retries OCC conflicts in memory. A dependency error returns a changeset
      through `Multi.error/3` and schedules nothing, since this variant persists no state.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent event processing.

  ## Main Functions

    * `process/2` — Entry point for processing update command maps with error handling and OCC.
    * `build_transaction/4` — Constructs Ecto.Multi operations for update actions.
    * `handle_build_transaction/3` — Adds the `:command_success` step, or a
      `Multi.error/3` step when the create dependency is unusable.
    * `handle_transaction_map_error/3` — Adds a `Multi.error/3` step carrying a
      changeset, so nothing is persisted.
    * `handle_occ_final_timeout/2` — Handles OCC retry exhaustion, does not persist.

  Atomic writes, OCC, and idempotency checks make concurrent retries safe. Error and retry
  outcomes are returned to the caller for further handling rather than being persisted.
  """

  use DoubleEntryLedger.Occ.Processor
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Occ.Helper
  import DoubleEntryLedger.CommandQueue.Scheduling

  import DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    only: [default_response_handler: 2]

  alias DoubleEntryLedger.JournalEvent
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Workers.CommandWorker

  alias Ecto.{Multi, Changeset}

  @impl true
  defdelegate handle_occ_final_timeout(command_map, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMapNoSaveOnError,
    as: :handle_occ_final_timeout

  @impl true
  defdelegate build_transaction(command_map, transaction_map, instance_id, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMap,
    as: :build_transaction

  @doc """
  Processes a `TransactionCommandMap` by creating both a command record and its associated transaction atomically, without saving on error.

  This function is designed for synchronous use, ensuring that both the command and the transaction are updated in one atomic operation. It handles `:update_transaction` only; a command map carrying any other action raises `FunctionClauseError`. The entire operation uses Optimistic Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively. If an error occurs, a changeset with error details is returned instead of persisting the error state.

  ## Parameters

    - `command_map`: A `TransactionCommandMap` struct containing all command and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, command}` on success, where both the transaction and command are created/updated successfully.
    - `{:error, changeset}` if validation or dependency errors occur (not persisted).
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(TransactionCommandMap.t(), Ecto.Repo.t() | nil) ::
          CommandWorker.success_tuple()
          | {:error, Changeset.t(TransactionCommandMap.t()) | String.t()}
  def process(%{action: :update_transaction} = command_map, repo \\ Repo) do
    case process_with_retry_no_save_on_error(command_map, repo) do
      {:error, :occ_timeout, %Changeset{data: %TransactionCommandMap{}} = changeset,
       _steps_so_far} ->
        warn("OCC timeout reached", command_map, changeset)

        {:error, changeset}

      {:error, :create_transaction_event_error,
       %Changeset{data: %TransactionCommandMap{}} = changeset, _steps_so_far} ->
        error("Update command error", command_map, changeset)

        {:error, changeset}

      response ->
        default_response_handler(response, command_map)
    end
  end

  @impl true
  @doc """
  Adds the step that marks the command processed once the transaction is written.

  On success the multi gains a `:command_success` step. On a dependency failure it
  gains `Multi.error/3` carrying a changeset, which rolls the transaction back: this
  variant persists no failure state, so nothing is reverted, retried or dead-lettered.

  ## Parameters

    - `multi`: The `Ecto.Multi` built so far.
    - `command_map`: The event map being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi`: a `:command_success` step on success, or a
      `Multi.error/3` step named `:create_transaction_event_error` carrying a
      changeset when the create command it depends on is unusable.
  """
  def handle_build_transaction(multi, command_map, _repo) do
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

      %{get_create_transaction_event_error: %{reason: reason}, new_command: _event} ->
        command_map_changeset =
          cast_to_command_map(command_map)
          |> TransactionCommandMap.changeset(%{})
          |> Changeset.add_error(:create_transaction_event_error, to_string(reason))

        Multi.new()
        |> Multi.error(:create_transaction_event_error, command_map_changeset)
    end)
  end

  @impl true
  @doc """
  Returns an `Ecto.Multi` containing a single `Multi.error/3` step whose changeset
  carries the error, so the transaction rolls back and nothing is persisted.
  """
  def handle_transaction_map_error(command_map, error, _repo) do
    command_map_changeset =
      cast_to_command_map(command_map)
      |> TransactionCommandMap.changeset(%{})
      |> Changeset.add_error(:input_command_map, to_string(error))

    Multi.new()
    |> Multi.error(:input_command_map_error, command_map_changeset)
  end

  defp cast_to_command_map(%TransactionCommandMap{} = command_map), do: command_map
  # Only cast if it's a plain map
  defp cast_to_command_map(command_map) when is_map(command_map),
    do: struct(TransactionCommandMap, command_map)
end
