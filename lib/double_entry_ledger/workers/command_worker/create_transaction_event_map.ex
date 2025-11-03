defmodule DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEventMap do
  @moduledoc """
  Processes `TransactionEventMap` structures for atomic creation and update of events and their
  associated transactions in the Double Entry Ledger system.

  This module implements the Optimistic Concurrency Control (OCC) pattern to ensure
  safe concurrent processing of events, providing robust error handling, retry logic,
  and transactional guarantees. It supports both creation and update flows for events,
  ensuring that all operations are performed atomically and consistently.

  ## Features

    * Transaction Processing: Handles both creation and update of transactions based on the event map's action.
    * Atomic Operations: Ensures all event and transaction changes are performed in a single database transaction.
    * Error Handling: Maps validation and dependency errors to the appropriate changeset or event state.
    * Retry Logic: Retries OCC conflicts and schedules retries for dependency errors.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent event processing.
  ## Main Functions

    * `process_map/2` — Entry point for processing event maps with error handling and OCC.
    * `build_transaction/3` — Constructs Ecto.Multi operations for create or update actions.
    * `handle_build_transaction/3` — Adds event update or error handling steps to the Multi.

  This module ensures that events are processed exactly once, even in high-concurrency
  environments, and that all error and retry scenarios are handled transparently.
  """
  use DoubleEntryLedger.Occ.Processor
  use DoubleEntryLedger.Logger

  alias DoubleEntryLedger.{Command, Repo, JournalEvent, PendingTransactionLookup}
  alias DoubleEntryLedger.Command.TransactionEventMap
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Stores.{CommandStoreHelper, TransactionStoreHelper}

  alias Ecto.Multi

  import DoubleEntryLedger.Workers.CommandWorker.TransactionEventMapResponseHandler,
    only: [default_response_handler: 2]

  import DoubleEntryLedger.CommandQueue.Scheduling

  @impl true
  @doc """
  Handles errors that occur when converting event map data to a transaction map.

  Delegates to `DoubleEntryLedger.Workers.CommandWorker.TransactionEventResponseHandler.handle_transaction_map_error/3`.

  ## Parameters

    - `event_map`: The event map being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  defdelegate handle_transaction_map_error(event_map, error, repo),
    as: :handle_transaction_map_error,
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionEventMapResponseHandler

  @impl true
  @doc """
  Handles the case when OCC retries are exhausted for an event map.

  Delegates to `DoubleEntryLedger.Workers.CommandWorker.TransactionEventResponseHandler.handle_occ_final_timeout/2`.

  ## Parameters

    - `event_map`: The event map being processed.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out.
  """
  defdelegate handle_occ_final_timeout(event_map, repo),
    as: :handle_occ_final_timeout,
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionEventResponseHandler

  @doc """
  Processes an `TransactionEventMap` by creating both an event record and its associated transaction atomically.

  This function is designed for synchronous use, ensuring that both the event and the transaction
  are created or updated in one atomic operation. It handles both `:create_transaction` and `:update` action types,
  with appropriate transaction building logic for each case. The entire operation uses Optimistic
  Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively.

  ## Parameters

    - `event_map`: An `TransactionEventMap` struct containing all event and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, event}` on success, where both the transaction and event are created/updated successfully.
    - `{:error, event}` if the transaction processing fails with an OCC or dependency issue:
      - If there was an OCC timeout, the event will be in the `:occ_timeout` state and can be retried.
      - If this is an update event and the create event is still in pending state, the event will be in the `:pending` state.
    - `{:error, changeset}` if validation errors occur:
      - For event validation failures, the TransactionEventMap changeset will contain event-related errors.
      - For transaction validation failures, the TransactionEventMap changeset will contain mapped transaction errors.
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(TransactionEventMap.t(), Ecto.Repo.t() | nil) ::
          CommandWorker.success_tuple() | CommandWorker.error_tuple()
  def process(%{action: :create_transaction} = event_map, repo \\ Repo) do
    case process_with_retry(event_map, repo) do
      {:ok, %{event_failure: %{command_queue_item: %{errors: [last_error | _]}} = event}} ->
        warn("#{last_error.message}", event)
        {:error, event}

      response ->
        default_response_handler(response, event_map)
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

    - `event_map`: An `TransactionEventMap` struct containing the event details and action type.
    - `transaction_map`: A map containing the transaction data to be created or updated.
    - `repo`: The Ecto repository to use for database operations.

  ## Returns

    - An `Ecto.Multi` struct containing the operations to execute within a transaction.
  """
  def build_transaction(
        %{action: :create_transaction} = event_map,
        transaction_map,
        instance_id,
        repo
      ) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:new_event, fn _ ->
      CommandStoreHelper.build_create(new_event_map, instance_id)
    end)
    |> Multi.insert(:journal_event, fn %{new_event: %{event_map: em}} ->
      JournalEvent.build_create(%{event_map: em, instance_id: instance_id})
    end)
    |> TransactionStoreHelper.build_create(:transaction, transaction_map, repo)
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
    - `event_map`: The event map being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with either an `:event_success` or `:event_failure` step.
  """
  def handle_build_transaction(multi, %{payload: %{status: :pending}} = event_map, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: %{id: tid}, new_event: %{id: cid} = command, journal_event: %{id: jid}} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(command)
        end)
        |> Multi.insert(:pending_transaction_lookup, fn _ ->
          attrs = %{
            command_id: cid,
            source: event_map.source,
            source_idempk: event_map.source_idempk,
            instance_id: command.instance_id,
            transaction_id: tid,
            journal_event_id: jid
          }

          PendingTransactionLookup.upsert_changeset(%PendingTransactionLookup{}, attrs)
        end)
        |> Oban.insert(:create_transaction_link, fn _ ->
          Workers.Oban.CreateTransactionLink.new(%{
            command_id: cid,
            transaction_id: tid,
            journal_event_id: jid
          })
        end)
    end)
  end

  def handle_build_transaction(multi, _event_map, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: %{id: tid}, new_event: %{id: cid} = command, journal_event: %{id: jid}} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(command)
        end)
        |> Oban.insert(:create_transaction_link, fn _ ->
          Workers.Oban.CreateTransactionLink.new(%{
            command_id: cid,
            transaction_id: tid,
            journal_event_id: jid
          })
        end)
    end)
  end
end
