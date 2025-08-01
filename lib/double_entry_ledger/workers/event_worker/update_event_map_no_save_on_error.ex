defmodule DoubleEntryLedger.EventWorker.UpdateEventMapNoSaveOnError do
  @moduledoc """
  Processes `EventMap` structures for atomic update of events and their associated transactions in the Double Entry Ledger system, without saving on error.

  Implements the Optimistic Concurrency Control (OCC) pattern to ensure safe concurrent processing of update events, providing robust error handling, retry logic, and transactional guarantees. This module ensures that update operations are performed atomically and consistently, and that all error and retry scenarios are handled transparently. Unlike the standard update event map processor, this variant does not persist changes on error, but instead returns changesets with error details for client handling.

  ## Features

    * Transaction Processing: Handles update of transactions based on the event map's action.
    * Atomic Operations: Ensures all event and transaction changes are performed in a single database transaction.
    * Error Handling: Maps validation and dependency errors to the appropriate changeset or event state, but does not persist on error.
    * Retry Logic: Retries OCC conflicts and schedules retries for dependency errors.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent event processing.

  ## Main Functions

    * `process/2` — Entry point for processing update event maps with error handling and OCC.
    * `build_transaction/3` — Constructs Ecto.Multi operations for update actions.
    * `handle_build_transaction/3` — Adds event update or error handling steps to the Multi.
    * `handle_transaction_map_error/3` — Returns a changeset with error details, does not persist.
    * `handle_occ_final_timeout/2` — Handles OCC retry exhaustion, does not persist.

  This module ensures that update events are processed exactly once, even in high-concurrency environments, and that all error and retry scenarios are handled transparently and returned to the caller for further handling.
  """

  use DoubleEntryLedger.Occ.Processor
  import DoubleEntryLedger.Occ.Helper
  import DoubleEntryLedger.EventWorker.ResponseHandler
  import DoubleEntryLedger.EventQueue.Scheduling

  import DoubleEntryLedger.EventWorker.ResponseHandler,
    only: [default_event_map_response_handler: 3]

  alias DoubleEntryLedger.{
    EventWorker,
    Repo
  }

  alias DoubleEntryLedger.Event.EventMap

  alias Ecto.{Multi, Changeset}

  # this function will never be called, as we don't save on error
  # but we need to implement it to satisfy the behaviour
  @impl true
  defdelegate handle_occ_final_timeout(event_map, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_occ_final_timeout

  @impl true
  defdelegate build_transaction(event_map, transaction_map, repo),
    to: DoubleEntryLedger.EventWorker.UpdateEventMap,
    as: :build_transaction

  @doc """
  Processes an `EventMap` by creating both an event record and its associated transaction atomically, without saving on error.

  This function is designed for synchronous use, ensuring that both the event and the transaction are created or updated in one atomic operation. It handles both `:create` and `:update` action types, with appropriate transaction building logic for each case. The entire operation uses Optimistic Concurrency Control (OCC) with retry mechanisms to handle concurrent modifications effectively. If an error occurs, a changeset with error details is returned instead of persisting the error state.

  ## Parameters

    - `event_map`: An `EventMap` struct containing all event and transaction data.
    - `repo`: The repository to use for database operations (defaults to `Repo`).

  ## Returns

    - `{:ok, transaction, event}` on success, where both the transaction and event are created/updated successfully.
    - `{:error, changeset}` if validation or dependency errors occur (not persisted).
    - `{:error, reason}` for other errors, with a string describing the error and the failing step.
  """
  @spec process(EventMap.t(), Ecto.Repo.t() | nil) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process(%{action: :update} = event_map, repo \\ Repo) do
    case process_with_retry_no_save_on_error(event_map, repo) do
      {:error, :occ_timeout, %Changeset{data: %EventMap{}} = changeset, _steps_so_far} ->
        Logger.warning(
          "#{@module_name}: OCC timeout reached",
          EventMap.log_trace(event_map, changeset.errors)
        )

        {:error, changeset}

      {:error, :create_event_error, %Changeset{data: %EventMap{}} = changeset, _steps_so_far} ->
        Logger.error(
          "#{@module_name}: Update event error",
          EventMap.log_trace(event_map, changeset.errors)
        )

        {:error, changeset}

      {:error, :input_event_map_error, %Changeset{data: %EventMap{}} = changeset, _steps_so_far} ->
        Logger.error(
          "#{@module_name}: Input event map error",
          EventMap.log_trace(event_map, changeset.errors)
        )

        {:error, changeset}

      response ->
        default_event_map_response_handler(response, event_map, @module_name)
    end
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

  If an error occurs, a changeset with error details is returned instead of persisting the error state.

  ## Parameters

    - `multi`: The `Ecto.Multi` built so far.
    - `event_map`: The event map being processed.
    - `_repo`: The Ecto repository (unused).

  ## Returns

    - The updated `Ecto.Multi` with either an `:event_success` or `:event_failure` step, or a changeset with error details.
  """
  def handle_build_transaction(multi, event_map, _repo) do
    multi
    |> Multi.merge(fn
      %{transaction: transaction, new_event: event} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(event)
        end)
        |> Multi.insert(:event_transaction_link, fn _ ->
          build_create_event_transaction_link(event, transaction)
        end)

      %{get_create_event_error: %{reason: reason}, new_event: _event} ->
        event_map_changeset =
          cast_to_event_map(event_map)
          |> EventMap.changeset(%{})
          |> Changeset.add_error(:create_event_error, to_string(reason))

        Multi.new()
        |> Multi.error(:create_event_error, event_map_changeset)
    end)
  end

  @impl true
  @doc """
  Returns a changeset with error details for the given event map and error, without persisting the error.

  This function is used to handle errors in transaction mapping, providing a changeset that
  describes the error without affecting the database state.
  """
  def handle_transaction_map_error(event_map, error, _repo) do
    event_map_changeset =
      cast_to_event_map(event_map)
      |> EventMap.changeset(%{})
      |> Changeset.add_error(:input_event_map, to_string(error))

    Multi.new()
    |> Multi.error(:input_event_map_error, event_map_changeset)
  end

  defp cast_to_event_map(%EventMap{} = event_map), do: event_map
  # Only cast if it's a plain map
  defp cast_to_event_map(event_map) when is_map(event_map), do: struct(EventMap, event_map)
end
