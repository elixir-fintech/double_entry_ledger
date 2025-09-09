defmodule DoubleEntryLedger.Event.TransferErrors do
  @moduledoc """
    Provides functions to extract and manipulate error information from Ecto changesets.
  """
  @type event_map ::
          DoubleEntryLedger.Event.AccountEventMap.t()
          | DoubleEntryLedger.Event.TransactionEventMap.t()

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.{AccountEventMap, TransactionEventMap, AccountData, TransactionData, EntryData}

  @spec transfer_errors_from_account_to_event_map(AccountEventMap.t(), Ecto.Changeset.t()) ::
          Ecto.Changeset.t(AccountEventMap.t())
  def transfer_errors_from_account_to_event_map(event_map, account_changeset) do
    build_event_map_changeset(event_map)
    |> Changeset.put_embed(
      :payload,
      build_payload_changeset(event_map, account_changeset)
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
  @spec transfer_errors_from_event_to_event_map(event_map, Changeset.t()) ::
          Changeset.t()
  def transfer_errors_from_event_to_event_map(event_map, event_changeset) do
    build_event_map_changeset(event_map)
    |> transfer_errors_between_changesets(event_changeset, [:update_idempk, :source_idempk])
    |> Map.put(:action, :insert)
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
  @spec transfer_errors_from_transaction_to_event_map(TransactionEventMap.t(), Ecto.Changeset.t()) ::
          Ecto.Changeset.t()
  def transfer_errors_from_transaction_to_event_map(event_map, trx_changeset) do
    build_event_map_changeset(event_map)
    |> Changeset.put_embed(
      :payload,
      build_payload_changeset(event_map, trx_changeset)
    )
    |> Map.put(:action, :insert)
  end

  @spec get_all_errors(Changeset.t()) :: map()
  def get_all_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @spec add_errors_to_changeset(Changeset.t(), atom(), map()) :: Changeset.t()
  def add_errors_to_changeset(changeset, field, errors) do
    if Map.has_key?(errors, field) do
      Map.get(errors, field)
      |> Enum.reduce(changeset, &Changeset.add_error(&2, field, &1))
    else
      changeset
    end
  end

  @spec transfer_errors_between_changesets(
          Changeset.t(),
          Changeset.t(),
          list(atom())
        ) ::
          Changeset.t()
  def transfer_errors_between_changesets(changeset, entity_changeset, keys) do
    errors = get_all_errors(entity_changeset)

    keys
    |> Enum.reduce(changeset, &add_errors_to_changeset(&2, &1, errors))
  end

  @spec build_event_map_changeset(event_map) :: Changeset.t()
  def build_event_map_changeset(%AccountEventMap{} = event_map) do
    %AccountEventMap{}
    |> AccountEventMap.changeset(AccountEventMap.to_map(event_map))
  end

  def build_event_map_changeset(%TransactionEventMap{} = event_map) do
    %TransactionEventMap{}
    |> TransactionEventMap.changeset(TransactionEventMap.to_map(event_map))
  end

  @spec build_payload_changeset(event_map, Changeset.t()) :: Changeset.t()
  def build_payload_changeset(%{payload: %AccountData{} = payload}, account_changeset) do
    %AccountData{}
    |> AccountData.changeset(AccountData.to_map(payload))
    |> transfer_errors_between_changesets(account_changeset, [:name, :type, :currency])
    |> Map.put(:action, :insert)
  end

  def build_payload_changeset(%{payload: %TransactionData{} = payload}, transaction_changeset) do
    %TransactionData{}
    |> TransactionData.changeset(TransactionData.to_map(payload))
    |> transfer_errors_between_changesets(transaction_changeset, [:status])
    |> Changeset.put_embed(
      :entries,
      get_entry_changesets_with_errors(payload, transaction_changeset)
    )
    |> Map.put(:action, :insert)
  end

  @doc false
  @spec add_entry_data_errors(Changeset.t(), map()) :: Changeset.t()
  defp add_entry_data_errors(changeset, entry_errors) do
    [:currency, :amount, :account_id]
    |> Enum.reduce(changeset, &add_errors_to_changeset(&2, &1, entry_errors))
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
  @spec get_entry_errors(Changeset.t()) :: [map()]
  defp get_entry_errors(trx_changeset) do
    get_all_errors(trx_changeset)
    |> Map.get(:entries, [])
  end
end
