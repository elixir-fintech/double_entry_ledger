defmodule DoubleEntryLedger.EventQueueItem do
  @moduledoc """
  Schema for the event queue table, used for worker-based queue management.
  This schema is used to track events that need to be processed by workers.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias DoubleEntryLedger.Event

  @states [:pending, :processed, :failed, :occ_timeout, :processing, :dead_letter]
  @type state ::
          unquote(
            Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_queue_items" do
    field :status, Ecto.Enum, values: @states, default: :pending
    field :processor_id, :string
    field :processor_version, :integer, default: 1
    field :processing_started_at, :utc_datetime_usec
    field :processing_completed_at, :utc_datetime_usec
    field :retry_count, :integer, default: 0
    field :next_retry_after, :utc_datetime_usec
    field :occ_retry_count, :integer, default: 0
    field :errors, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)

    belongs_to :event, Event, type: Ecto.UUID
  end

  @doc false
  def changeset(event_queue_item, attrs) do
    event_queue_item
    |> cast(attrs, [
      :status,
      :processor_id,
      :processor_version,
      :processing_started_at,
      :processing_completed_at,
      :retry_count,
      :next_retry_after,
      :occ_retry_count,
      :errors,
      :event_id
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @states)
  end

  @spec processing_start_changeset(Event.t(), String.t()) :: Ecto.Changeset.t()
  def processing_start_changeset(event_queue_item, processor_id) do
    event_queue_item
    |> change(%{
      status: :processing,
      processor_id: processor_id,
      processing_started_at: DateTime.utc_now(),
      processing_completed_at: nil,
      retry_count: event_queue_item.retry_count + 1,
      next_retry_after: nil
    })
    |> optimistic_lock(:processor_version)
  end
end
