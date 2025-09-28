defmodule DoubleEntryLedger.Workers.EventWorker.TransactionEventResponseHandler do
  @moduledoc """
  Specialized error handling for the event processing pipeline in the double-entry ledger system.

  This module provides utilities for processing, transforming, and propagating errors that occur
  during event processing. It handles error mapping between different data structures
  (transactions, events, event maps) while maintaining detailed error context.

  Key responsibilities:
  - Transfer validation errors from event/transaction changesets to event map changesets
  - Maintain error context and traceability for audit and troubleshooting
  - Build structured error responses for client consumption and retry logic

  Examples

      # Map event validation errors to an event map changeset
      iex> default_event_map_response_handler(
      ...>   {:error, :new_event, event_changeset, %{}},
      ...>   event_map,
      ...>   "MyWorker"
      ...> )
      {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.TransactionEventMap{}}}

      # Map transaction validation errors to an event map changeset
      iex> default_event_map_response_handler(
      ...>   {:error, :transaction, trx_changeset, %{}},
      ...>   event_map,
      ...>   "MyWorker"
      ...> )
      {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.TransactionEventMap{}}}
  """
  require Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [build_schedule_retry_with_reason: 3, schedule_retry_with_reason: 3]

  import DoubleEntryLedger.Event.TransferErrors,
    only: [
      from_event_to_event_map: 2,
      from_transaction_to_event_map_payload: 2,
      get_all_errors_with_opts: 1
    ]

  alias Ecto.{Changeset, Multi}

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventWorker
  }

  alias DoubleEntryLedger.Event.TransactionEventMap

  alias DoubleEntryLedger.Occ.Occable

  @doc """
  Default response handler for functions that operate on a TransactionEventMap.

  Returns:
  - `{:ok, transaction, event}` on success
  - `{:error, changeset}` when either the event or transaction changeset fails,
    with errors mapped onto an event map changeset
  - `{:error, message}` for other failures
  """
  @spec default_event_map_response_handler(
          {:ok, map()} | {:error, :atom, any(), map()},
          TransactionEventMap.t(),
          String.t()
        ) ::
          EventWorker.success_tuple()
          | {:error, Changeset.t(TransactionEventMap.t()) | String.t()}
  def default_event_map_response_handler(
        response,
        %TransactionEventMap{} = event_map,
        module_name
      ) do
    case response do
      {:ok, %{transaction: transaction, event_success: event}} ->
        Logger.info(
          "#{module_name}: processed successfully",
          Event.log_trace(event, transaction)
        )

        {:ok, transaction, event}

      {:error, :new_event, %Changeset{data: %Event{}} = event_changeset, _steps_so_far} ->
        Logger.warning(
          "#{module_name}: Event changeset failed",
          TransactionEventMap.log_trace(event_map, get_all_errors_with_opts(event_changeset))
        )

        {:error, from_event_to_event_map(event_map, event_changeset)}

      {:error, :transaction, %Changeset{data: %Transaction{}} = trx_changeset, _steps_so_far} ->
        Logger.warning(
          "#{module_name}: Transaction changeset failed",
          TransactionEventMap.log_trace(event_map, get_all_errors_with_opts(trx_changeset))
        )

        {:error, from_transaction_to_event_map_payload(event_map, trx_changeset)}

      {:error, step, error, _steps_so_far} ->
        message = "#{module_name}: Step :#{step} failed."

        Logger.error(
          message,
          TransactionEventMap.log_trace(event_map, error)
        )

        {:error, "#{message} #{inspect(error)}"}
    end
  end

  @doc """
  Default response handler when starting from a stored Event.

  Returns:
  - `{:ok, transaction, event}` on success
  - `{:error, event}` when the event pipeline returns a structured failure
  - schedules a retry and returns `{:error, message}` for other failures
  """
  @spec default_event_response_handler(
          {:ok, map()} | {:error, :atom, any(), map()},
          Event.t(),
          String.t()
        ) ::
          EventWorker.success_tuple() | {:error, Event.t() | String.t()}
  def default_event_response_handler(response, %Event{} = original_event, module_name) do
    case response do
      {:ok, %{event_success: event, transaction: transaction}} ->
        Logger.info(
          "#{module_name}: processed successfully",
          Event.log_trace(event, transaction)
        )

        {:ok, transaction, event}

      {:ok, %{event_failure: %{event_queue_item: %{errors: [last_error | _]}} = event}} ->
        Logger.warning("#{module_name}: #{last_error.message}", Event.log_trace(event))
        {:error, event}

      {:error, step, error, _} ->
        message = "#{module_name}: Step :#{step} failed."
        Logger.error(message, Event.log_trace(original_event, error))

        schedule_retry_with_reason(
          original_event,
          "#{message} Error: #{inspect(error)}",
          :failed
        )
    end
  end

  @doc """
  Handles errors that occur during transaction map conversion.

  Schedules a retry for the given occable item, marking it as failed.

  ## Parameters

    - `occable_item`: The event or event map being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository (unused).

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  @spec handle_transaction_map_error(Occable.t(), any(), Ecto.Repo.t()) :: Multi.t()
  def handle_transaction_map_error(occable_item, error, _repo) do
    Multi.update(Multi.new(), :event_failure, fn _ ->
      build_schedule_retry_with_reason(occable_item, error, :failed)
    end)
  end

  @doc """
  Handles the case when OCC retries are exhausted.

  Schedules a retry for the given occable item, marking it as OCC timeout.

  ## Parameters

    - `occable_item`: The event or event map being processed.
    - `repo`: The Ecto repository (unused).

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out.
  """
  @spec handle_occ_final_timeout(Occable.t(), Ecto.Repo.t()) :: Multi.t()
  def handle_occ_final_timeout(occable_item, _repo) do
    Multi.update(Multi.new(), :event_failure, fn _ ->
      build_schedule_retry_with_reason(
        occable_item,
        nil,
        :occ_timeout
      )
    end)
  end
end
