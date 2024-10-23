defmodule DoubleEntryLedger.Event.TransactionData do
  @moduledoc """
    TransactionData for the Event
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states DoubleEntryLedger.Transaction.states

  alias DoubleEntryLedger.Transaction
  alias DoubleEntryLedger.Event.EntryData
  alias __MODULE__, as: TransactionData


  @type t :: %TransactionData{
    status: Transaction.state(),
    entries: [EntryData.t()]
  }

  @primary_key false
  embedded_schema do
    field :status, Ecto.Enum, values: @states
    embeds_many :entries, EntryData
  end

  @doc false
  def changeset(transaction_data, attrs) do
    transaction_data
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @states)
    |> cast_embed(:entries, with: &EntryData.changeset/2, required: true)
    |> validate_entries_count()
  end

  def update_event_changeset(transaction_data, %{status: :posted} = attrs) do
    if Map.has_key?(attrs, :entries) do
      changeset(transaction_data, attrs)
    else
      transaction_data
      |> cast(attrs, [:status])
    end
  end

  def update_event_changeset(transaction_data, %{status: :archived} = attrs) do
    transaction_data
    |> cast(attrs, [:status])
  end

  def update_event_changeset(transaction_data, attrs) do
    changeset(transaction_data, attrs)
  end

  defp validate_entries_count(changeset) do
    entries = get_field(changeset, :entries, [])
    if length(entries) < 2 do
      add_error(changeset, :entries, "must have at least 2 entries")
    else
      changeset
    end
  end
end
