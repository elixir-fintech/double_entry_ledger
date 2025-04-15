defmodule DoubleEntryLedger.EventWorker.ProcessEventMap do
  @moduledoc """
  Provides functionality to process EventMap structures in the Double Entry Ledger system.

  This module is responsible for the atomic creation and update of events and their
  associated transactions, implementing the Optimistic Concurrency Control (OCC) pattern
  to handle concurrent modifications safely.

  ## Key Features

  * **Transaction Processing**: Handles both creation of new transactions and updates to
    existing transactions based on the EventMap's action type (:create or :update)

  * **Atomic Operations**: Ensures that events and their transactions are processed in a single
    database transaction, maintaining data consistency

  * **Error Handling**: Provides comprehensive error handling for validation failures,
    OCC conflicts, and dependency issues between events

  * **Retry Logic**: Implements automatic retry mechanisms to handle temporary concurrency
    conflicts

  ## Main Functions

  * `process_map/2`: Entry point for processing event maps, with comprehensive error handling
  * `build_transaction/3`: Constructs appropriate Ecto.Multi operations based on event action type

  The module integrates with the OCC processor behavior to handle retries and concurrency
  control, ensuring that events are processed exactly once even in high-concurrency
  environments.
  """
  use DoubleEntryLedger.Occ.Processor

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    TransactionStore,
    Repo,
    EventStoreHelper
  }

  alias DoubleEntryLedger.Event.EventMap

  alias DoubleEntryLedger.EventWorker.AddUpdateEventError

  alias Ecto.{Multi, Changeset}
  import DoubleEntryLedger.Occ.Helper
  import DoubleEntryLedger.EventWorker.ErrorHandler

  @doc """
  Processes an EventMap by creating both an event record and its associated transaction atomically.

  This function is designed for synchronous use, ensuring that both the event and the transaction
  are created or updated in one atomic operation. It handles both :create and :update action types,
  with appropriate transaction building logic for each case. The entire operation uses Optimistic
  Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively.

  ## Parameters
    - `event_map`: An EventMap struct containing all event and transaction data
    - `repo`: The repository to use for database operations (defaults to `Repo`)

  ## Returns
    - `{:ok, transaction, event}` on success, where both the transaction and event are created/updated successfully
    - `{:error, event}` if the transaction processing fails with an OCC or dependency issue:
      - If there was an OCC timeout, the event will be in the :occ_timeout state and can be retried
      - If this is an update event and the create event is still in pending state, the event will be in the :pending state
    - `{:error, changeset}` if validation errors occur:
      - For event validation failures, the EventMap changeset will contain event-related errors
      - For transaction validation failures, the EventMap changeset will contain mapped transaction errors
    - `{:error, reason}` for other errors, with a string describing the error and the failing step
  """
  @spec process_map(EventMap.t(), Ecto.Repo.t() | nil) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process_map(event_map, repo \\ Repo) do
    case process_with_retry(event_map, repo) do
      {:ok, %{transaction: transaction, event: event}} ->
        {:ok, transaction, event}

      {:error, :transaction, :occ_final_timeout, event} ->
        {:error, event}

      {:error, :get_create_event_transaction, %AddUpdateEventError{} = error, steps_so_far} ->
        {:error, handle_add_update_event_error(error, steps_so_far, event_map)}

      {:error, :create_event, %Changeset{data: %Event{}} = event_changeset, _steps_so_far} ->
        {:error, transfer_errors_from_event_to_event_map(event_map, event_changeset)}

      {:error, :transaction, %Changeset{data: %Transaction{}} = trx_changeset, _steps_so_far} ->
        {:error, transfer_errors_from_trx_to_event_map(event_map, trx_changeset)}

      {:error, step, error, _steps_so_far} ->
        {:error, "#{step} failed: #{inspect(error)}"}
    end
  end

  @doc """
  Builds an Ecto.Multi transaction for processing an event map based on its action type.

  This function implements the OccProcessor behavior and creates the appropriate
  transaction operations depending on whether the event is a :create or :update action.

  For :create actions:
  - Inserts a new event with status :pending
  - Creates a new transaction in the ledger
  - Updates the event to mark it as processed with the transaction ID

  For :update actions:
  - Inserts a new event with status :pending
  - Retrieves the related "create event" transaction
  - Updates the existing transaction with new data
  - Updates the event to mark it as processed with the transaction ID

  ## Parameters
    - `event_map`: An EventMap struct containing the event details and action type
    - `transaction_map`: A map containing the transaction data to be created or updated
    - `repo`: The Ecto repository to use for database operations

  ## Returns
    - An `Ecto.Multi` struct containing the operations to execute within a transaction
  """
  @impl true
  def build_transaction(%{action: :create} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStoreHelper.build_create(new_event_map))
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStoreHelper.build_mark_as_processed(event, transaction.id)
    end)
  end

  def build_transaction(%{action: :update} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStoreHelper.build_create(new_event_map))
    |> EventStoreHelper.build_get_create_event_transaction(
      :get_create_event_transaction,
      :create_event
    )
    |> TransactionStore.build_update(
      :transaction,
      :get_create_event_transaction,
      transaction_map,
      repo
    )
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStoreHelper.build_mark_as_processed(event, transaction.id)
    end)
  end
end
