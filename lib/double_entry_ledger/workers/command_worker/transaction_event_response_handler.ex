defmodule DoubleEntryLedger.Workers.CommandWorker.TransactionEventResponseHandler do
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

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [
      build_schedule_retry_with_reason: 3,
      schedule_retry_with_reason: 3,
      build_mark_as_dead_letter: 2,
      mark_as_dead_letter: 2
    ]

  alias Ecto.{Multi, Changeset}
  alias DoubleEntryLedger.Occ.Occable

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Workers.CommandWorker

  @doc """
  Default response handler when starting from a stored Event.

  Returns:
  - `{:ok, transaction, event}` on success
  - `{:error, event}` when the event pipeline returns a structured failure
  - schedules a retry and returns `{:error, message}` for other failures
  """
  @spec default_response_handler(
          {:ok, map()} | {:error, :atom, any(), map()},
          Event.t()
        ) ::
          CommandWorker.success_tuple() | {:error, Event.t() | Changeset.t()}
  def default_response_handler(response, %Event{} = original_event) do
    case response do
      {:ok, %{event_success: event, transaction: transaction}} ->
        info("Processed successfully", event, transaction)

        {:ok, transaction, event}

      {:ok, %{event_failure: %{event_queue_item: %{errors: [last_error | _]}} = event}} ->
        warn("#{last_error.message}", event)

        {:error, event}

      {:error, :transaction, changeset, _} ->
        {:ok, message} = warn("Transaction changeset failed", original_event, changeset)
        mark_as_dead_letter(original_event, message)

      {:error, step, error, _} ->
        {:ok, message} = error("Step :#{step} failed.", original_event, error)

        schedule_retry_with_reason(original_event, message, :failed)
    end
  end

  @doc """
  Handles errors that occur during transaction map conversion.

  Marks the event_queue_item as dead_letter

  ## Parameters

    - `occable_item`: The event being processed.
    - `error`: The error encountered during transaction map conversion.
    - `repo`: The Ecto repository (unused).

  ## Returns

    - An `Ecto.Multi` that updates the event with error information.
  """
  @spec handle_transaction_map_error(Event.t(), any(), Ecto.Repo.t()) :: Multi.t()
  def handle_transaction_map_error(event, error, _repo) do
    Multi.update(Multi.new(), :event_failure, fn _ ->
      build_mark_as_dead_letter(event, error)
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
