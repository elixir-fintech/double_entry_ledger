defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
  Provides functions to process event maps by creating event records and handling associated transactions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Event.TransactionData

  alias __MODULE__, as: EventMap

  @type t :: %EventMap{
    action: Event.action(),
    instance_id: String.t(),
    source: String.t(),
    source_data: map(),
    source_idempk: String.t(),
    update_idempk: String.t() | nil,
    transaction_data: TransactionData.t()
  }

  @primary_key false
  embedded_schema do
    field :action, Ecto.Enum, values: Event.actions
    field :instance_id, :string
    field :source, :string
    field :source_data, :map, default: %{}
    field :source_idempk, :string
    field :update_idempk, :string
    embeds_one :transaction_data, TransactionData
  end

  def changeset(event_map, attrs) do
    event_map
    |> cast(attrs, [:action, :instance_id, :source, :source_data, :source_idempk, :update_idempk])
    |> validate_required([:action, :instance_id, :source, :source_idempk])
    |> validate_inclusion(:action, Event.actions)
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  @doc """
  Converts an event struct (of type t) into its map representation.
  It also converts the nested transaction data into its map representation.

  This function is useful for transforming the event structure into a plain map,
  which can be easily serialized, inspected, or manipulated further.

  ## Example

    iex> alias DoubleEntryLedger.Event.TransactionData
    iex> alias DoubleEntryLedger.Event.EventMap
    iex> event = %EventMap{transaction_data: %TransactionData{}}
    iex> is_map(EventMap.to_map(event))
    true
  """
  @spec to_map(t) :: map()
  def to_map(event_map) do
    %{
      action: event_map.action,
      instance_id: event_map.instance_id,
      source: event_map.source,
      source_data: event_map.source_data,
      source_idempk: event_map.source_idempk,
      update_idempk: event_map.update_idempk,
      transaction_data: TransactionData.to_map(event_map.transaction_data)
    }
  end
end
