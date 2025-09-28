defmodule DoubleEntryLedger.Workers.EventWorker.UpdateTransactionEvent do
  @moduledoc """
  Processes update (transaction) events in the double-entry ledger system.

  This module handles the complete lifecycle of update events, which modify existing
  transactions in the ledger system. It implements optimistic concurrency control (OCC)
  to handle potential conflicts when multiple processes attempt to update the same
  transaction.

  ## Workflow

    1. Retrieves the original transaction created by a creation event.
    2. Applies modifications specified in the update event.
    3. Handles potential conflicts using retry mechanisms.
    4. Updates the event status based on the operation result.

  ## Error Handling

  Comprehensive error handling is provided for:
    - Pending create events (update attempted before create is complete)
    - Optimistic concurrency failures (OCC conflicts)
    - General processing errors

  ## Main Functions

    * `process/2` — Entry point for processing an update event.
    * `build_transaction/3` — Constructs the Ecto.Multi for transaction update.
    * `handle_build_transaction/3` — Adds event update or error handling steps to the Multi.
    * `handle_transaction_map_error/3` — Handles errors in transaction map conversion.
    * `handle_occ_final_timeout/2` — Handles OCC retry exhaustion.
  """

  use DoubleEntryLedger.Occ.Processor

  alias Ecto.Multi

  alias DoubleEntryLedger.{
    Event,
    EventWorker,
    EventStoreHelper,
    TransactionStoreHelper,
    Repo
  }

  alias DoubleEntryLedger.Workers.EventWorker.UpdateEventError
  import DoubleEntryLedger.EventQueue.Scheduling

  import DoubleEntryLedger.Workers.EventWorker.TransactionEventResponseHandler,
    only: [default_event_response_handler: 3]

  @impl true
  @doc """
  Handles errors that occur when converting event data to a transaction map.

  Delegates to `DoubleEntryLedger.Workers.EventWorker.TransactionEventResponseHandler.handle_transaction_map_error/3`.

  ## Parameters

    - `event_map`: The event being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  defdelegate handle_transaction_map_error(event_map, error, repo),
    to: DoubleEntryLedger.Workers.EventWorker.TransactionEventResponseHandler,
    as: :handle_transaction_map_error

  @impl true
  @doc """
  Handles the case when OCC retries are exhausted.

  Delegates to `DoubleEntryLedger.Workers.EventWorker.TransactionEventResponseHandler.handle_occ_final_timeout/2`.

  ## Parameters

    - `event_map`: The event being processed.
    - `repo`: The Ecto repository.

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out.
  """
  defdelegate handle_occ_final_timeout(event_map, repo),
    to: DoubleEntryLedger.Workers.EventWorker.TransactionEventResponseHandler,
    as: :handle_occ_final_timeout

  @doc """
  Processes an update event by modifying the corresponding transaction.

  This function serves as the main entry point for processing update events.
  It utilizes optimistic concurrency control with retry logic to handle
  potential conflicts when multiple processes attempt to update the same
  transaction simultaneously.

  ## Parameters

    - `event`: The `%Event{}` struct with action `:update` to process.
    - `repo`: The Ecto repo to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, event}`: Successfully processed the update event.
    - `{:error, event}`: Failed to process the event, with the event containing error details.
    - `{:error, changeset}`: Failed to update the event status, with changeset containing validation errors.
    - `{:error, reason}`: Failed to process the event, with reason explaining the failure.

  ## Error Handling

    - Handles create events that are still pending.
    - Handles optimistic concurrency conflicts with retries.
    - Properly marks events as failed with meaningful error messages.
  """
  @spec process(Event.t(), Ecto.Repo.t()) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process(original_event, repo \\ Repo) do
    process_with_retry(original_event, repo)
    |> default_event_response_handler(original_event, @module_name)
  end

  @impl true
  @doc """
  Builds a multi-step transaction for updating a transaction record.

  This function implements the OCC.Processor behavior by constructing an
  Ecto.Multi that:

    1. Retrieves the original transaction created by a creation event.
    2. Updates the transaction with the new attributes.
    3. Marks the update event as processed.

  ## Parameters

    - `event`: The update event being processed.
    - `attr`: The attributes to apply to the transaction.
    - `repo`: The Ecto repo to use for database operations.

  ## Returns

    - An `Ecto.Multi` struct with named operations for transaction processing.
  """
  def build_transaction(%Event{} = event, attr, repo) do
    Multi.new()
    |> EventStoreHelper.build_get_create_transaction_event_transaction(
      :get_create_event_transaction,
      event
    )
    |> Multi.merge(fn
      %{get_create_event_transaction: {:error, %UpdateEventError{} = exception}} ->
        Multi.put(Multi.new(), :get_create_transaction_event_error, exception)

      %{get_create_event_transaction: create_transaction} ->
        TransactionStoreHelper.build_update(
          Multi.new(),
          :transaction,
          create_transaction,
          attr,
          repo
        )
    end)
  end

  @impl true
  @doc """
  Adds the step to update the event or handle errors after transaction processing.

  This function inspects the results of the previous Multi steps and determines
  whether to mark the event as processed, revert it to pending, schedule a retry,
  or move it to the dead letter queue.

  ## Parameters

    - `multi`: The Ecto.Multi built so far.
    - `event`: The event being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with an `:event_success` or `:event_failure` step.
  """
  def handle_build_transaction(multi, event, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: transaction} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(event)
        end)
        |> Multi.insert(:event_transaction_link, fn _ ->
          build_create_transaction_event_transaction_link(event, transaction)
        end)

      %{
        get_create_transaction_event_error: %{reason: :create_event_not_processed} = exception
      } ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_revert_to_pending(event, exception.message)
        end)

      %{
        get_create_transaction_event_error: %{reason: :create_event_failed} = exception
      } ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_schedule_update_retry(event, exception)
        end)

      %{get_create_transaction_event_error: exception} ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_mark_as_dead_letter(event, exception.message)
        end)
    end)
  end
end
