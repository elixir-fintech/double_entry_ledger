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
    if length(entries) < 2 do
      add_error(changeset, :entries, "must have at least 2 entries")
    else
      changeset
    end
  end

  defp validate_distinct_account_ids(changeset) do
    entries = get_field(changeset, :entries, [])
    account_ids = Enum.map(entries, & &1.account_id)

    if length(account_ids) != length(Enum.uniq(account_ids)) do
      add_error(changeset, :entries, "account IDs must be distinct")
    else
      changeset
    end
  end
end
