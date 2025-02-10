defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
  Provides functions to process event maps by creating event records and handling associated transactions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.{Event, Instance}
  alias DoubleEntryLedger.Event.TransactionData

  alias __MODULE__, as: EventMap


  @type t :: %EventMap{
    action: Event.action(),
    instance_id: Ecto.UUID.t() | nil,
    source: String.t(),
    source_data: map(),
    source_idempk: String.t(),
    update_idempk: String.t() | nil,
    transaction_data: TransactionData.t()
  }

  @primary_key false
  embedded_schema do
    field :action, Ecto.Enum, values: Event.actions
    belongs_to :instance, Instance, type: Ecto.UUID
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
end
