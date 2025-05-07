defmodule DoubleEntryLedger.EventWorker.UpdateEvent do
  @moduledoc """
  Processes update events in the double-entry ledger system.

  This module handles the complete lifecycle of update events, which modify existing
  transactions in the ledger system. It implements optimistic concurrency control (OCC)
  to handle potential conflicts when multiple processes attempt to update the same
  transaction.

  The update event processing:
  1. Retrieves the original transaction created by a creation event
  2. Applies modifications specified in the update event
  3. Handles potential conflicts using retry mechanisms
  4. Updates the event status based on the operation result

  Error handling is comprehensive, with specific error paths for:
  - Pending create events (update attempted before create is complete)
  - Optimistic concurrency failures
  - General processing errors
  """

  use DoubleEntryLedger.Occ.Processor

  alias Ecto.Changeset
  alias Ecto.Multi

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStoreHelper,
    TransactionStore,
    Repo
  }

  alias DoubleEntryLedger.EventWorker.AddUpdateEventError
  import DoubleEntryLedger.EventQueue.Scheduling

  @doc """
  Processes an update event by modifying the corresponding transaction.

  This function serves as the main entry point for processing update events.
  It utilizes optimistic concurrency control with retry logic to handle
  potential conflicts when multiple processes attempt to update the same
  transaction simultaneously.

  ## Parameters
    - `event` - The %Event{} struct with action :update to process
    - `repo` - The Ecto repo to use for database operations (defaults to Repo)

  ## Returns
    - `{:ok, transaction, event}` - Successfully processed the update event
    - `{:error, event}` - Failed to process the event, with the event containing error details
    - `{:error, changeset}` - Failed to update the event status, with changeset containing validation errors
    - `{:error, reason}` - Failed to process the event, with reason explaining the failure

  ## Error Handling
    - Handles create events that are still pending
    - Handles optimistic concurrency conflicts with retries
    - Properly marks events as failed with meaningful error messages
  """
  @spec process_update_event(Event.t(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process_update_event(event, repo \\ Repo) do
    case process_with_retry(event, repo) do
      {:ok, %{transaction: transaction, event: update_event}} ->
        {:ok, transaction, update_event}

      {:error, :transaction_map, error, event} ->
        schedule_retry(event, error, :failed)

      {:error, :get_create_event_transaction, error, _} ->
        handle_get_create_event_transaction_error(event, error)

      {:error, :transaction, :occ_final_timeout, event} ->
        schedule_retry(
          event,
          "transaction step failed: Optimistic concurrency control timeout",
          :occ_timeout
        )

      {:error, step, error, _} ->
        schedule_retry(event, "#{step} step failed: #{inspect(error)}", :failed)
    end
  end

  @doc """
  Builds a multi-step transaction for updating a transaction record.

  This function implements the OCC.Processor behavior by constructing an
  Ecto.Multi that:
  1. Retrieves the original transaction created by a creation event
  2. Updates the transaction with the new attributes
  3. Marks the update event as processed

  ## Parameters
    - `event` - The update event being processed
    - `attr` - The attributes to apply to the transaction
    - `repo` - The Ecto repo to use for database operations

  ## Returns
    - An Ecto.Multi struct with named operations for transaction processing
  """
  @impl true
  def build_transaction(event, attr, repo) do
    Multi.new()
    |> EventStoreHelper.build_get_create_event_transaction(:get_create_event_transaction, event)
    |> TransactionStore.build_update(:transaction, :get_create_event_transaction, attr, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      build_mark_as_processed(event, td.id)
    end)
  end

  @spec handle_get_create_event_transaction_error(Event.t(), AddUpdateEventError.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  def handle_get_create_event_transaction_error(event, error) do
    case error do
      %{reason: :create_event_pending} ->
        revert_to_pending(event, error.message)

      %{reason: :create_event_failed} ->
        schedule_update_retry(event, error)

      _ ->
        move_to_dead_letter(event, error.message)
    end
  end
end
