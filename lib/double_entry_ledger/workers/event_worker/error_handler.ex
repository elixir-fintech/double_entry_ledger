defmodule DoubleEntryLedger.EventWorker.ErrorHandler do
  @moduledoc """
  Specialized error handling for the event processing pipeline in the double-entry ledger system.

  This module provides utilities for processing, transforming, and propagating errors that occur
  during event processing. It handles complex error mapping between different data structures
  (transactions, events, event maps) while maintaining detailed error context.

  ## Key Responsibilities

    * Transferring validation errors between different system layers
    * Maintaining error context and traceability
    * Handling dependency errors between related events
    * Building properly structured error changesets for client consumption

  The error handler ensures that all validation failures, processing errors, and
  dependency issues are properly captured for troubleshooting, auditing, and potential
  retry operations.
  """

  alias Ecto.{Changeset, Multi}
  import DoubleEntryLedger.Event.ErrorMap
  import DoubleEntryLedger.EventQueue.Scheduling, only: [build_schedule_retry_with_reason: 3]

  alias DoubleEntryLedger.{
    Event,
    EventStore
  }

  alias DoubleEntryLedger.Event.{
    EntryData,
    TransactionData,
    EventMap
  }

  alias DoubleEntryLedger.EventWorker.{
    AddUpdateEventError
  }

  alias DoubleEntryLedger.Occ.Occable

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

  @doc """
  Maps transaction validation errors to an event map changeset.

  When a transaction fails validation during event processing, this function ensures
  those errors are properly reflected in the event map structure, maintaining full
  error context and attribution.

  ## Parameters

    - `event_map`: The event map used to generate the transaction
    - `trx_changeset`: Transaction changeset containing validation errors

  ## Returns

    - `Ecto.Changeset.t()`: Event map changeset with propagated errors
  """
  @spec transfer_errors_from_trx_to_event_map(EventMap.t(), Ecto.Changeset.t()) ::
          Ecto.Changeset.t()
  def transfer_errors_from_trx_to_event_map(event_map, trx_changeset) do
    build_event_map_changeset(event_map)
    |> Changeset.put_embed(
      :transaction_data,
      build_transaction_data_changeset(event_map, trx_changeset)
    )
    |> Map.put(:action, :insert)
  end

  @doc """
  Maps event validation errors to an event map changeset.

  When an event fails validation during creation or update, this function ensures
  those errors are properly reflected in the event map structure, maintaining full
  error context and attribution.

  ## Parameters

    - `event_map`: The original event map
    - `event_changeset`: Event changeset containing validation errors

  ## Returns

    - `Ecto.Changeset.t()`: Event map changeset with propagated errors
  """
  @spec transfer_errors_from_event_to_event_map(EventMap.t(), Changeset.t()) :: Changeset.t()
  def transfer_errors_from_event_to_event_map(event_map, event_changeset) do
    build_event_map_changeset(event_map)
    |> add_event_errors(get_all_errors(event_changeset))
    |> Map.put(:action, :insert)
  end

  @doc """
  Handles errors related to dependencies between update events and their create events.

  This function provides specialized error handling for update events that depend on
  create events which are not in the proper state. It distinguishes between different
  error scenarios (pending, failed, or not found) and handles each appropriately.

  ## Parameters

    - `error`: An AddUpdateEventError exception containing details about the error
    - `steps_so_far`: A map containing processing steps completed before the error occurred
    - `event_map`: The original event map being processed

  ## Returns

    - `Event.t()`: For pending create events, creates a new event with pending status
    - `Changeset.t()`: For other errors, returns a changeset with mapped errors
  """
  @spec handle_add_update_event_error(AddUpdateEventError.t(), map(), EventMap.t()) ::
          Event.t() | Changeset.t()
  def handle_add_update_event_error(
        %{reason: :create_event_pending, message: msg},
        steps_so_far,
        event_map
      ) do
    case EventStore.create_event_after_failure(
           steps_so_far[:create_event],
           [build_error(msg)],
           1,
           :pending
         ) do
      {:ok, event} ->
        event

      {:error, changeset} ->
        transfer_errors_from_event_to_event_map(event_map, changeset)
    end
  end

  def handle_add_update_event_error(%{message: msg}, steps_so_far, event_map) do
    steps_so_far[:create_event]
    |> Changeset.change()
    |> Changeset.add_error(:source_idempk, "#{msg}")
    |> then(&transfer_errors_from_event_to_event_map(event_map, &1))
  end

  @doc false
  @spec build_event_map_changeset(EventMap.t()) :: Changeset.t()
  defp build_event_map_changeset(event_map) do
    %EventMap{}
    |> EventMap.changeset(EventMap.to_map(event_map))
  end

  @doc false
  @spec build_transaction_data_changeset(EventMap.t(), Changeset.t()) :: Changeset.t()
  defp build_transaction_data_changeset(%{transaction_data: transaction_data}, trx_changeset) do
    %TransactionData{}
    |> TransactionData.changeset(TransactionData.to_map(transaction_data))
    |> add_transaction_data_errors(trx_changeset)
    |> Changeset.put_embed(
      :entries,
      get_entry_changesets_with_errors(transaction_data, trx_changeset)
    )
    |> Map.put(:action, :insert)
  end

  @doc false
  @spec add_transaction_data_errors(Changeset.t(), Changeset.t()) :: Changeset.t()
  defp add_transaction_data_errors(changeset, trx_changeset) do
    errors = get_all_errors(trx_changeset)

    [:status]
    |> Enum.reduce(changeset, &add_errors_to_changeset(&2, &1, errors))
  end

  @doc false
  @spec add_entry_data_errors(Changeset.t(), map()) :: Changeset.t()
  defp add_entry_data_errors(changeset, entry_errors) do
    [:currency, :amount, :account_id]
    |> Enum.reduce(changeset, &add_errors_to_changeset(&2, &1, entry_errors))
  end

  @doc false
  @spec add_event_errors(Changeset.t(), map()) :: Changeset.t()
  defp add_event_errors(event_map_changeset, errors) do
    [:update_idempk, :source_idempk]
    |> Enum.reduce(event_map_changeset, &add_errors_to_changeset(&2, &1, errors))
  end

  @doc false
  @spec get_entry_changesets_with_errors(TransactionData.t(), map()) :: [Changeset.t()]
  defp get_entry_changesets_with_errors(%{entries: entries}, trx_changeset) do
    entry_errors = get_entry_errors(trx_changeset)

    entries
    |> Enum.with_index()
    |> Enum.map(&build_entry_data_changeset(&1, entry_errors))
  end

  @doc false
  @spec build_entry_data_changeset({EntryData.t(), integer()}, list()) :: Changeset.t()
  defp build_entry_data_changeset({entry_data, index}, entry_errors) do
    %EntryData{}
    |> EntryData.changeset(EntryData.to_map(entry_data))
    |> add_entry_data_errors(Enum.at(entry_errors, index))
    |> Map.put(:action, :insert)
  end

  @doc false
  @spec get_all_errors(Changeset.t()) :: map()
  defp get_all_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @doc false
  @spec get_entry_errors(Changeset.t()) :: [map()]
  defp get_entry_errors(trx_changeset) do
    get_all_errors(trx_changeset)
    |> Map.get(:entries, [])
  end

  @doc false
  @spec add_errors_to_changeset(Changeset.t(), atom(), map()) :: Changeset.t()
  defp add_errors_to_changeset(changeset, field, errors) do
    if Map.has_key?(errors, field) do
      Map.get(errors, field)
      |> Enum.reduce(changeset, &Changeset.add_error(&2, field, &1))
    else
      changeset
    end
  end
end
