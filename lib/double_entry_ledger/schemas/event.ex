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
    action: :create | :update,
    source: String.t(),
    source_data: map(),
    source_id: String.t(),
    processed_at: DateTime.t() | nil,
    payload: DoubleEntryLedger.EventPayload.t() | nil,
    inserted_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @states [:pending, :processed, :failed]
  @actions [:create, :update]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "events" do
    field :status, Ecto.Enum, values: @states, default: :pending
    field :action, Ecto.Enum, values: @actions
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
    |> cast(attrs, [:action, :source, :source_data, :source_id])
    |> validate_required([:action, :source, :source_id])
    |> validate_inclusion(:action, @actions)
    |> cast_embed(:payload, with: &DoubleEntryLedger.EventPayload.changeset/2, required: true)
  end
end
