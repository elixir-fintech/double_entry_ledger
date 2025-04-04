defmodule DoubleEntryLedger.EventWorker.ErrorHandler do
  @moduledoc """
  This module provides functions to handle errors that occur during the processing of events in the Double Entry Ledger system.
  """

  alias Ecto.Changeset
  alias DoubleEntryLedger.EventStore

  alias DoubleEntryLedger.Event.{
    EntryData,
    TransactionData,
    EventMap
  }

  alias DoubleEntryLedger.EventWorker.{
    AddUpdateEvent
  }

  @type event_error_map :: %{
          errors:
            list(%{
              message: String.t(),
              inserted_at: DateTime.t()
            }),
          steps_so_far: map(),
          retries: integer()
        }

  @spec build_errors(String.t(), list()) :: list()
  def build_errors(error_message, errors) do
    [build_error(error_message) | errors]
  end

  @spec build_error(String.t()) :: %{message: String.t(), inserted_at: DateTime.t()}
  def build_error(error) do
    %{
      message: error,
      inserted_at: DateTime.utc_now(:microsecond)
    }
  end

  @spec transfer_errors_from_trx_to_event_map(EventMap.t(), Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def transfer_errors_from_trx_to_event_map(event_map, trx_changeset) do
    build_event_map_changeset(event_map)
    |> Changeset.put_embed(
        :transaction_data,
        build_transaction_data_changeset(event_map, trx_changeset)
      )
    |> Map.put(:action, :insert)
  end

  @spec transfer_errors_from_event_to_event_map(EventMap.t(), Changeset.t()) :: Changeset.t()
  def transfer_errors_from_event_to_event_map(event_map, event_changeset) do
    build_event_map_changeset(event_map)
    |> add_event_errors(get_all_errors(event_changeset))
    |> Map.put(:action, :insert)
  end

  @spec build_event_map_changeset(EventMap.t()) :: Changeset.t()
  defp build_event_map_changeset(event_map) do
    %EventMap{}
    |> EventMap.changeset(EventMap.to_map(event_map))
  end

  @spec build_transaction_data_changeset(EventMap.t(), Changeset.t()) :: Changeset.t()
  defp build_transaction_data_changeset(%{transaction_data: transaction_data}, trx_changeset) do
    %TransactionData{}
    |> TransactionData.changeset(TransactionData.to_map(transaction_data))
    |> Changeset.put_embed(:entries, get_entry_changesets_with_errors(transaction_data, trx_changeset))
    |> Map.put(:action, :insert)
  end

  @spec handle_add_update_event_error(AddUpdateEvent.t(), map(), EventMap.t()) :: Event.t() | Changeset.t()
  def handle_add_update_event_error(%AddUpdateEvent{reason: :create_event_pending, message: msg}, steps_so_far, event_map) do
    case EventStore.create_event_after_failure(steps_so_far[:create_event], [build_error(msg)], 1, :pending) do
      {:ok, event} ->
        event

      {:error, changeset} ->
        transfer_errors_from_event_to_event_map(event_map, changeset)
      end
  end

  def handle_add_update_event_error(%AddUpdateEvent{message: msg}, steps_so_far, event_map) do
    steps_so_far[:create_event]
    |> Changeset.change()
    |> Changeset.add_error(:source_idempk, "#{msg}")
    |> then(&transfer_errors_from_event_to_event_map(event_map, &1))
  end

  @spec add_entry_data_errors(Changeset.t(), map()) :: Changeset.t()
  defp add_entry_data_errors(changeset, entry_errors) do
    [:currency, :amount, :account_id]
    |> Enum.reduce(changeset, &add_errors_to_changeset(&2, &1, entry_errors))
  end

  @spec add_event_errors(Changeset.t(), map()) :: Changeset.t()
  defp add_event_errors(event_map_changeset, errors) do
    [:update_idempk, :source_idempk]
    |> Enum.reduce(event_map_changeset, &add_errors_to_changeset(&2, &1, errors))
  end

  @spec get_entry_changesets_with_errors(TransactionData.t(), map()) :: [Changeset.t()]
  defp get_entry_changesets_with_errors(%{entries: entries }, trx_changeset) do
    entry_errors = get_entry_errors(trx_changeset)
    entries
    |> Enum.with_index()
    |> Enum.map(&build_entry_data_changeset(&1, entry_errors))
  end

  @spec build_entry_data_changeset({EntryData.t(), integer()}, list()) :: Changeset.t()
  defp build_entry_data_changeset({entry_data, index}, entry_errors) do
    %EntryData{}
    |> EntryData.changeset(EntryData.to_map(entry_data))
    |> add_entry_data_errors(Enum.at(entry_errors, index))
    |> Map.put(:action, :insert)
  end

  @spec get_all_errors(Changeset.t()) :: map()
  defp get_all_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @spec get_entry_errors(Changeset.t()) :: [map()]
  defp get_entry_errors(trx_changeset) do
    get_all_errors(trx_changeset)
    |> Map.get(:entries, [])
  end

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
