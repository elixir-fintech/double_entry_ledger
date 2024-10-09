defmodule DoubleEntryLedger.Event do
  @moduledoc """
  This module defines the Event schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__, as: Event
  @type t :: %Event{
    id: Ecto.UUID.t(),
    status: :pending | :processed | :failed,
    event_type: :create | :update,
    source: String.t(),
    source_data: map(),
    source_id: String.t(),
    processed_at: DateTime.t() | nil,
    payload: DoubleEntryLedger.EventPayload.t() | nil,
    inserted_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @states [:pending, :processed, :failed]
  @event_types [:create, :update]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "events" do
    field :status, Ecto.Enum, values: @states, default: :pending
    field :event_type, Ecto.Enum, values: @event_types
    field :source, :string
    field :source_data, :map, default: %{}
    field :source_id, :string
    field :processed_at, :utc_datetime_usec

    embeds_one :payload, DoubleEntryLedger.EventPayload

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:status, :event_type, :source])
    |> validate_required([:status, :event_type, :source])
    |> cast_embed(:payload, with: &DoubleEntryLedger.EventPayload.changeset/2)
  end
end
