defmodule DoubleEntryLedger.EventWorker.CreateEvent do
  @moduledoc """
  Handles the processing of creation events in the double-entry ledger system.

  This module is responsible for transforming event data into ledger transactions
  and creating those transactions within the accounting system. It implements
  optimistic concurrency control (OCC) to handle potential conflicts when
  multiple processes attempt to create transactions simultaneously.

  ## Workflow

    1. Receives an event with `action: :create_transaction`
    2. Transforms the event's transaction data into a valid transaction map
    3. Attempts to create a transaction in the database
    4. If successful, marks the event as processed and links it to the created transaction
    5. If unsuccessful due to concurrency issues, implements retry logic
    6. If unsuccessful due to other errors, marks the event as failed

  ## Error Handling

  The module implements comprehensive error handling with specific error types:
    - Transaction map transformation errors
    - Database transaction errors
    - OCC retry exhaustion errors

  Each error is recorded in the event's history for auditability.

  ## Main Functions

    * `process/2` — Entry point for processing a create event.
    * `build_transaction/3` — Constructs the Ecto.Multi for transaction creation.
    * `handle_build_transaction/3` — Adds event update step to the Multi.
    * `handle_transaction_map_error/3` — Handles errors in transaction map conversion.
    * `handle_occ_final_timeout/2` — Handles OCC retry exhaustion.
  """

  use DoubleEntryLedger.Occ.Processor

  alias Ecto.Multi
  alias DoubleEntryLedger.{Event, EventWorker, TransactionStore, Repo}

  import DoubleEntryLedger.EventQueue.Scheduling

  import DoubleEntryLedger.EventWorker.ResponseHandler,
    only: [default_event_response_handler: 3]

  @impl true
  @doc """
  Handles errors that occur when converting event data to a transaction map.

  Delegates to `DoubleEntryLedger.EventWorker.ResponseHandler.handle_transaction_map_error/3`.

  ## Parameters

    - `event_map`: The event being processed.
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
  Handles the case when OCC retries are exhausted.

  Delegates to `DoubleEntryLedger.EventWorker.ResponseHandler.handle_occ_final_timeout/2`.

  ## Parameters

    - `event_map`: The event being processed.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out.
  """
  defdelegate handle_occ_final_timeout(event_map, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_occ_final_timeout

  @doc """
  Processes a create event by transforming it into a transaction in the ledger.

  Takes an event with `action: :create_transaction` and attempts to transform its data into
  a valid transaction. Handles the complete lifecycle of transaction creation,
  including optimistic concurrency control, error handling, and event status updates.

  ## Parameters

    - `event`: An `Event` struct containing the transaction data to be processed.
    - `repo`: (Optional) The Ecto repository to use for database operations, defaults to `Repo`.

  ## Returns

    - `{:ok, transaction, event}`: When transaction creation succeeds.
    - `{:error, event}`: When processing fails due to OCC timeout.
    - `{:error, changeset}`: When there's a validation error or database error.
    - `{:error, reason}`: When another error occurs, with a reason explaining the failure.
  """
  @spec process(Event.t(), Ecto.Repo.t()) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process(%Event{action: :create_transaction} = original_event, repo \\ Repo) do
    process_with_retry(original_event, repo)
    |> default_event_response_handler(original_event, @module_name)
  end

  @impl true
  @doc """
  Builds the Ecto.Multi for creating a transaction from an event.

  ## Parameters

    - `event`: The event to process.
    - `transaction_map`: The transaction data map derived from the event.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that inserts the transaction.
  """
  def build_transaction(_event, transaction_map, repo) do
    Multi.new()
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
  end

  @impl true
  @doc """
  Adds the step to mark the event as processed after transaction creation.

  ## Parameters

    - `multi`: The Ecto.Multi built so far.
    - `event`: The event being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with an `:event_success` update step.
  """
  def handle_build_transaction(multi, event, _repo) do
    multi
    |> Multi.update(:event_success, fn _ ->
      build_mark_as_processed(event)
    end)
    |> Multi.insert(:event_transaction_link, fn %{transaction: transaction} ->
      build_create_transaction_event_transaction_link(event, transaction)
    end)
  end
end
