defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMap do
  @moduledoc """
  Processes `TransactionCommandMap` structures for atomic update of events and their associated transactions in the Double Entry Ledger system.

  Implements the Optimistic Concurrency Control (OCC) pattern to ensure safe concurrent processing of update events, providing robust error handling, retry logic, and transactional guarantees. This module ensures that update operations are performed atomically and consistently, and that all error and retry scenarios are handled transparently.

  ## Features

    * Transaction Processing: Handles update of transactions based on the event map's action.
    * Atomic Operations: Ensures all event and transaction changes are performed in a single database transaction.
    * Error Handling: Maps validation and dependency errors to the appropriate changeset or event state.
    * Retry Logic: Retries OCC conflicts and schedules retries for dependency errors.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent event processing.

  ## Main Functions

    * `process/2` — Entry point for processing update event maps with error handling and OCC.
    * `build_transaction/3` — Constructs Ecto.Multi operations for update actions.
    * `handle_build_transaction/3` — Adds event update or error handling steps to the Multi.

  This module ensures that update events are processed exactly once, even in high-concurrency environments, and that all error and retry scenarios are handled transparently.
  """

  use DoubleEntryLedger.Occ.Processor
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Occ.Helper
  import DoubleEntryLedger.CommandQueue.Scheduling

  import DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    only: [default_response_handler: 2]

  alias DoubleEntryLedger.{Command, JournalEvent, Repo}

  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Stores.{CommandStoreHelper, TransactionStoreHelper}
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError
  alias Ecto.Multi

  @impl true
  @doc """
  Handles errors that occur when converting event map data to a transaction map.

  Delegates to `DoubleEntryLedger.Workers.CommandWorker.TransactionCommandResponseHandler.handle_transaction_map_error/3`.

  ## Parameters

    - `command_map`: The event map being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  defdelegate handle_transaction_map_error(command_map, error, repo),
    to: Workers.CommandWorker.TransactionCommandResponseHandler,
    as: :handle_transaction_map_error

  @impl true
  @doc """
  Handles the case when OCC retries are exhausted for an event map.

  Delegates to `DoubleEntryLedger.Workers.CommandWorker.TransactionCommandResponseHandler.handle_occ_final_timeout/2`.

  ## Parameters

    - `command_map`: The event map being processed.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out.
  """
  defdelegate handle_occ_final_timeout(command_map, repo),
    to: Workers.CommandWorker.TransactionCommandResponseHandler,
    as: :handle_occ_final_timeout

  @doc """
  Processes an `TransactionCommandMap` by creating both an event record and its associated transaction atomically.

  This function is designed for synchronous use, ensuring that both the event and the transaction
  are created or updated in one atomic operation. It handles both `:create_transaction` and `:update` action types,
  with appropriate transaction building logic for each case. The entire operation uses Optimistic
  Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively.

  ## Parameters

    - `command_map`: An `TransactionCommandMap` struct containing all event and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, event}` on success, where both the transaction and event are created/updated successfully.
    - `{:error, event}` if the transaction processing fails with an OCC or dependency issue:
      - If there was an OCC timeout, the event will be in the `:occ_timeout` state and can be retried.
      - If this is an update event and the create event is still in pending state, the event will be in the `:pending` state.
    - `{:error, changeset}` if validation errors occur:
      - For event validation failures, the TransactionCommandMap changeset will contain event-related errors.
      - For transaction validation failures, the TransactionCommandMap changeset will contain mapped transaction errors.
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(TransactionCommandMap.t(), Ecto.Repo.t() | nil) ::
          CommandWorker.success_tuple() | CommandWorker.error_tuple()
  def process(%{action: :update_transaction} = command_map, repo \\ Repo) do
    case process_with_retry(command_map, repo) do
      {:ok, %{event_failure: %{command_queue_item: %{errors: [last_error | _]}} = event}} ->
        warn("#{last_error.message}", event)
        {:error, event}

      response ->
        default_response_handler(response, command_map)
    end
  end

  @impl true
  @doc """
  Builds an `Ecto.Multi` transaction for processing an event map based on its action type.

  This function implements the OCC processor behavior and creates the appropriate
  transaction operations depending on whether the event is a `:create_transaction` or `:update` action.

  ### For `:create_transaction` actions:
    - Inserts a new event with status `:pending`
    - Creates a new transaction in the ledger
    - Updates the event to mark it as processed with the transaction ID

  ### For `:update` actions:
    - Inserts a new event with status `:pending`
    - Retrieves the related "create event" transaction
    - Updates the existing transaction with new data
    - Updates the event to mark it as processed with the transaction ID

  ## Parameters

    - `command_map`: An `TransactionCommandMap` struct containing the event details and action type.
    - `transaction_map`: A map containing the transaction data to be created or updated.
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
  Adds the step to update the event or handle errors after transaction processing.

  This function inspects the results of the previous `Ecto.Multi` steps and determines
  the appropriate next action for the event:

    * If both the transaction and event creation succeed, the event is marked as processed.
    * If the related create event is not yet processed, the event is reverted to pending.
    * If the related create event failed, a retry is scheduled for the update event.
    * For all other errors, the event is marked as dead letter.

  ## Parameters

    - `multi`: The `Ecto.Multi` built so far.
    - `command_map`: The event map being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with either an `:event_success` or `:event_failure` step.
  """
  def handle_build_transaction(multi, _command_map, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: %{id: tid}, new_command: %{id: eid, command_map: em, instance_id: iid} = event} ->
        Multi.insert(Multi.new(), :journal_event, fn _ ->
          JournalEvent.build_create(%{command_map: em, instance_id: iid})
        end)
        |> Multi.update(:event_success, fn _ ->
          build_mark_as_processed(event)
        end)
        |> Oban.insert(:create_transaction_link, fn %{journal_event: %{id: jid}} ->
          Workers.Oban.JournalEventLinks.new(%{
            command_id: eid,
            transaction_id: tid,
            journal_event_id: jid
          })
        end)

      %{
        get_create_transaction_event_error: %{reason: :create_command_not_processed} = exception,
        new_command: event
      } ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_revert_to_pending(event, exception.message)
        end)

      %{get_create_transaction_event_error: exception, new_command: event} ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_mark_as_dead_letter(event, exception.message)
        end)
    end)
  end
end
