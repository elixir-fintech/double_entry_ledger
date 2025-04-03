defmodule DoubleEntryLedger.Event.TransactionData do
  @moduledoc """
    TransactionData for the Event
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states DoubleEntryLedger.Transaction.states

  @posted ["posted", :posted]
  @archived ["archived", :archived]

  alias DoubleEntryLedger.Transaction
  alias DoubleEntryLedger.Event.EntryData
  alias __MODULE__, as: TransactionData

  @derive {Jason.Encoder, only: [:status, :entries]}

  @type t :: %TransactionData{
    status: Transaction.state(),
    entries: [EntryData.t()]
  }

  @primary_key false
  embedded_schema do
    field :status, Ecto.Enum, values: @states
    embeds_many :entries, EntryData, on_replace: :delete
  end

  @doc false
  def changeset(transaction_data, attrs) do
    transaction_data
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @states)
    |> cast_embed(:entries, with: &EntryData.changeset/2, required: true)
    |> validate_entries_count()
    |> validate_distinct_account_ids()
  end

  def update_event_changeset(transaction_data, attrs) do
    # Extract status and entries from attrs regardless of key type.
    status = Map.get(attrs, "status") || Map.get(attrs, :status)
    entries = Map.get(attrs, "entries") || Map.get(attrs, :entries)

    cond do
      (entries in [[], nil]) and (status in @posted) ->
        cast(transaction_data, attrs, [:status])

      status in @archived ->
        cast(transaction_data, attrs, [:status])

      true ->
        changeset(transaction_data, attrs)
    end
  end

  @doc """
  Converts the given `TransactionData.t` struct to a map.

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionData
      iex> transaction_data = %TransactionData{}
      iex> TransactionData.to_map(transaction_data)
      %{status: nil, entries: []}

  """
  @spec to_map(t) :: map()
  def to_map(transaction_data) do
    %{
      status: transaction_data.status,
      entries: Enum.map(transaction_data.entries, &EntryData.to_map/1)
    }
  end

  defp validate_entries_count(changeset) do
    entries = get_field(changeset, :entries, [])
    cond do
      entries == [] ->
        add_error(changeset, :entry_count, "must have at least 2 entries")
      length(entries) == 1 ->
        add_error(changeset, :entry_count, "must have at least 2 entries")
        |> add_errors_to_entries(:account_id, "at least 2 accounts are required")
      true ->
        changeset
    end
  end

  defp validate_distinct_account_ids(changeset) do
    duplicate_ids =
      (get_embed(changeset, :entries, :struct) || [])
      |> Enum.map(& &1.account_id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {id, _} -> id end)

    if duplicate_ids != [] do
      add_errors_to_entries(changeset, :account_id, "account IDs must be distinct", duplicate_ids)
    else
      changeset
    end
  end

  @spec add_errors_to_entries(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  defp add_errors_to_entries(changeset, field, error) do
      (get_embed(changeset, :entries, :changeset) || [])
      |> Enum.map(&add_error(&1, field, error))
      |> then(&put_embed(changeset, :entries, &1))
  end

  @spec add_errors_to_entries(Ecto.Changeset.t(), atom(), String.t(), list(Ecto.UUID.t())) :: Ecto.Changeset.t()
  defp add_errors_to_entries(changeset, field, error, ids) do
      (get_embed(changeset, :entries, :changeset) || [])
      |> Enum.map(fn entry_changeset ->
        id = get_field(entry_changeset, field)
        if id in ids do
          add_error(entry_changeset, field, error)
        else
          entry_changeset
        end
      end)
      |> then(&put_embed(changeset, :entries, &1))
  end
end
