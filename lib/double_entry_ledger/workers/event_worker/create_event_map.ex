defmodule DoubleEntryLedger.EventWorker.CreateEventMap do
  @moduledoc """
  Processes `EventMap` structures for atomic creation and update of events and their
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

  alias DoubleEntryLedger.{
    Event,
    EventWorker,
    TransactionStore,
    Repo,
    EventStoreHelper
  }

  alias DoubleEntryLedger.Event.EventMap

  alias Ecto.Multi
  import DoubleEntryLedger.Occ.Helper

  import DoubleEntryLedger.EventWorker.ResponseHandler,
    only: [default_event_map_response_handler: 3]

  import DoubleEntryLedger.EventQueue.Scheduling

  @impl true
  @doc """
  Handles errors that occur when converting event map data to a transaction map.

  Delegates to `DoubleEntryLedger.EventWorker.ResponseHandler.handle_transaction_map_error/3`.

  ## Parameters

    - `event_map`: The event map being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  defdelegate handle_transaction_map_error(event_map, error, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_transaction_map_error

  @impl true
  @doc """
  Handles the case when OCC retries are exhausted for an event map.

  Delegates to `DoubleEntryLedger.EventWorker.ResponseHandler.handle_occ_final_timeout/2`.

  ## Parameters

    - `event_map`: The event map being processed.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out.
  """
  defdelegate handle_occ_final_timeout(event_map, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_occ_final_timeout

  @doc """
  Processes an `EventMap` by creating both an event record and its associated transaction atomically.

  This function is designed for synchronous use, ensuring that both the event and the transaction
  are created or updated in one atomic operation. It handles both `:create` and `:update` action types,
  with appropriate transaction building logic for each case. The entire operation uses Optimistic
  Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively.

  ## Parameters

    - `event_map`: An `EventMap` struct containing all event and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, event}` on success, where both the transaction and event are created/updated successfully.
    - `{:error, event}` if the transaction processing fails with an OCC or dependency issue:
      - If there was an OCC timeout, the event will be in the `:occ_timeout` state and can be retried.
      - If this is an update event and the create event is still in pending state, the event will be in the `:pending` state.
    - `{:error, changeset}` if validation errors occur:
      - For event validation failures, the EventMap changeset will contain event-related errors.
      - For transaction validation failures, the EventMap changeset will contain mapped transaction errors.
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(EventMap.t(), Ecto.Repo.t() | nil) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process(%{action: :create} = event_map, repo \\ Repo) do
    case process_with_retry(event_map, repo) do
      {:ok, %{event_failure: %{event_queue_item: %{errors: [last_error | _]}} = event}} ->
        Logger.warning("#{@module_name}: #{last_error.message}", Event.log_trace(event))
        {:error, event}

      response ->
        default_event_map_response_handler(response, event_map, @module_name)
    end
  end

  @impl true
  @doc """
  Builds an `Ecto.Multi` transaction for processing an event map based on its action type.

  This function implements the OCC processor behavior and creates the appropriate
  transaction operations depending on whether the event is a `:create` or `:update` action.

  ### For `:create` actions:
    - Inserts a new event with status `:pending`
    - Creates a new transaction in the ledger
    - Updates the event to mark it as processed with the transaction ID

  ### For `:update` actions:
    - Inserts a new event with status `:pending`
    - Retrieves the related "create event" transaction
    - Updates the existing transaction with new data
    - Updates the event to mark it as processed with the transaction ID

  ## Parameters

    - `event_map`: An `EventMap` struct containing the event details and action type.
    - `transaction_map`: A map containing the transaction data to be created or updated.
    - `repo`: The Ecto repository to use for database operations.

  ## Returns

    - An `Ecto.Multi` struct containing the operations to execute within a transaction.
  """
  def build_transaction(%{action: :create} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:new_event, EventStoreHelper.build_create(new_event_map))
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
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
  def handle_build_transaction(multi, _event_map, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: transaction, new_event: event} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(event)
        end)
        |> Multi.insert(:event_transaction_link, fn _ ->
          build_create_event_transaction_link(event, transaction)
        end)
    end)
  end
end
