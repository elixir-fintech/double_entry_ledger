defmodule DoubleEntryLedger.Workers.EventWorker.TransactionEventMapResponseHandler do
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
      iex> default_response_handler(
      ...>   {:error, :new_event, event_changeset, %{}},
      ...>   event_map,
      ...>   "MyWorker"
      ...> )
      {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.TransactionEventMap{}}}

      # Map transaction validation errors to an event map changeset
      iex> default_response_handler(
      ...>   {:error, :transaction, trx_changeset, %{}},
      ...>   event_map,
      ...>   "MyWorker"
      ...> )
      {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.TransactionEventMap{}}}
  """
  require Logger

  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.EventQueue.Scheduling, only: [build_schedule_retry_with_reason: 3]

  import DoubleEntryLedger.Event.TransferErrors,
    only: [
      from_event_to_event_map: 2,
      from_transaction_to_event_map_payload: 2,
      from_idempotency_key_to_event_map: 2
    ]

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.Occ.Occable
  alias DoubleEntryLedger.Event.{TransactionEventMap, IdempotencyKey}

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventWorker
  }

  @doc """
  Default response handler for functions that operate on a TransactionEventMap.

  Returns:
  - `{:ok, transaction, event}` on success
  - `{:error, changeset}` when either the event or transaction changeset fails,
    with errors mapped onto an event map changeset
  - `{:error, message}` for other failures
  """
  @spec default_response_handler(
          {:ok, map()} | {:error, :atom, any(), map()},
          TransactionEventMap.t()
        ) ::
          EventWorker.success_tuple()
          | {:error, Changeset.t(TransactionEventMap.t()) | String.t()}
  def default_response_handler(
        response,
        %TransactionEventMap{} = event_map
      ) do
    case response do
      {:ok, %{transaction: transaction, event_success: event}} ->
        info("Processed successfully", event, transaction)

        {:ok, transaction, event}

      {:error, :idempotency, %Changeset{data: %IdempotencyKey{}} = changeset, _} ->
        error("Idempotency violation", event_map, changeset)

        {:error, from_idempotency_key_to_event_map(event_map, changeset) }

      {:error, :input_event_map_error, %Changeset{data: %TransactionEventMap{}} = changeset, _} ->
        error("Input event map error", event_map, changeset)

        {:error, changeset}

      {:error, :new_event, %Changeset{data: %Event{}} = event_changeset, _steps_so_far} ->
        warn("Event changeset failed", event_map, event_changeset)

        {:error, from_event_to_event_map(event_map, event_changeset)}

      {:error, :transaction, %Changeset{data: %Transaction{}} = trx_changeset, _steps_so_far} ->
        warn("Transaction changeset failed", event_map, trx_changeset)

        {:error, from_transaction_to_event_map_payload(event_map, trx_changeset)}

      {:error, step, error, _steps_so_far} ->
        {:ok, message} = error("Step :#{step} failed.", event_map, error)

        {:error, "#{message} #{inspect(error)}"}
    end
  end

  @doc """
  Handles errors that occur during transaction map conversion.

  Schedules a retry for the given occable item, marking it as failed.

  ## Parameters

    - `occable_item`: The event map being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository (unused).

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  def handle_transaction_map_error(event_map, error, _repo) do
    event_map_changeset =
      event_map
      |> TransactionEventMap.changeset(%{})
      |> Changeset.add_error(:input_event_map, to_string(error))

    Multi.new()
    |> Multi.error(:input_event_map_error, event_map_changeset)
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
