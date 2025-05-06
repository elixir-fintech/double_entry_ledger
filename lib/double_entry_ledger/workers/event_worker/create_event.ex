defmodule DoubleEntryLedger.EventWorker.CreateEvent do
  @moduledoc """
  Handles the processing of creation events in the double-entry ledger system.

  This module is responsible for transforming event data into ledger transactions
  and creating those transactions within the accounting system. It implements
  optimistic concurrency control (OCC) to handle potential conflicts when
  multiple processes attempt to create transactions simultaneously.

  ## Workflow

  1. Receives an event with `action: :create`
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
  """

  use DoubleEntryLedger.Occ.Processor

  alias Ecto.{
    Changeset,
    Multi
  }

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStore,
    EventStoreHelper,
    TransactionStore,
    Repo
  }

  @doc """
  Processes a create event by transforming it into a transaction in the ledger.

  Takes an event with `action: :create` and attempts to transform its data into
  a valid transaction. Handles the complete lifecycle of transaction creation,
  including optimistic concurrency control, error handling, and event status updates.

  ## Parameters

    - `event`: An `Event` struct containing the transaction data to be processed
    - `repo`: (Optional) The Ecto repository to use for database operations, defaults to `Repo`

  ## Returns

    - `{:ok, transaction, event}`: When transaction creation succeeds
      - `transaction`: The newly created `Transaction` struct
      - `event`: The updated event with status `:processed`

    - `{:error, event}`: When processing fails due to OCC timeout
      - `event`: The updated event with error information

    - `{:error, changeset}`: When there's a validation error or database error
      - `changeset`: The Ecto changeset containing error details

  """
  @spec process_create_event(Event.t(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process_create_event(event, repo \\ Repo) do
    case process_with_retry(event, repo) do
      {:ok, %{transaction: transaction, event: update_event}} ->
        {:ok, transaction, update_event}

      {:error, :transaction, :occ_final_timeout, event} ->
        {:error, event}

      {:error, :transaction_map, error, event} ->
        handle_error(event, "Failed to transform transaction data: #{inspect(error)}")

      {:error, step, error, _} ->
        handle_error(event, "#{step} step failed: #{inspect(error)}")
    end
  end

  @impl true
  def build_transaction(event, transaction_map, repo) do
    Multi.new()
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStoreHelper.build_mark_as_processed(event, td.id)
    end)
  end

  @spec handle_error(Event.t(), String.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  defp handle_error(event, reason) do
    case EventStore.schedule_retry(event, reason) do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
