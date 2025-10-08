defmodule DoubleEntryLedger.EventQueueItem do
  @moduledoc """
  Schema for the event queue table, used for worker-based queue management.
  This schema is used to track events that need to be processed by workers.
  """

  use DoubleEntryLedger.BaseSchema
  import Ecto.Changeset
  alias DoubleEntryLedger.Workers.EventWorker.UpdateEventError
  alias DoubleEntryLedger.Event.ErrorMap
  alias DoubleEntryLedger.Event
  import DoubleEntryLedger.Event.ErrorMap, only: [build_error: 1]

  alias __MODULE__, as: EventQueueItem

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          status: state() | nil,
          processor_id: String.t() | nil,
          processor_version: integer() | nil,
          processing_started_at: DateTime.t() | nil,
          processing_completed_at: DateTime.t() | nil,
          retry_count: integer() | nil,
          next_retry_after: DateTime.t() | nil,
          occ_retry_count: integer() | nil,
          errors: list(map()) | nil,
          event_id: Ecto.UUID.t() | nil
        }

  @states [:pending, :processed, :failed, :occ_timeout, :processing, :dead_letter]
  @type state ::
          unquote(
            Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )

  @derive {Jason.Encoder, only: [:status, :processing_completed_at, :retry_count, :next_retry_after, :errors]}

  schema "event_queue_items" do
    field(:status, Ecto.Enum, values: @states, default: :pending)
    field(:processor_id, :string)
    field(:processor_version, :integer, default: 1)
    field(:processing_started_at, :utc_datetime_usec)
    field(:processing_completed_at, :utc_datetime_usec)
    field(:retry_count, :integer, default: 0)
    field(:next_retry_after, :utc_datetime_usec)
    field(:occ_retry_count, :integer, default: 0)
    field(:errors, {:array, :map}, default: [])

    timestamps(type: :utc_datetime_usec)

    belongs_to(:event, Event, type: Ecto.UUID)
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

  @spec processing_start_changeset(EventQueueItem.t(), String.t(), non_neg_integer()) :: Ecto.Changeset.t()
  def processing_start_changeset(event_queue_item, processor_id, retry_count) do
    event_queue_item
    |> change(%{
      status: :processing,
      processor_id: processor_id,
      processing_started_at: DateTime.utc_now(),
      processing_completed_at: nil,
      retry_count: retry_count,
      next_retry_after: nil
    })
    |> optimistic_lock(:processor_version)
  end

  @spec processing_complete_changeset(EventQueueItem.t()) :: Ecto.Changeset.t()
  def processing_complete_changeset(event_queue_item) do
    event_queue_item
    |> change(%{
      status: :processed,
      processing_completed_at: DateTime.utc_now(),
      next_retry_after: nil
    })
  end

  @spec revert_to_pending_changeset(EventQueueItem.t(), any()) :: Ecto.Changeset.t()
  def revert_to_pending_changeset(event_queue_item, error \\ nil) do
    event_queue_item
    |> change(%{
      status: :pending,
      errors: build_errors(event_queue_item, error)
    })
  end

  @spec dead_letter_changeset(EventQueueItem.t(), any()) :: Ecto.Changeset.t()
  def dead_letter_changeset(event_queue_item, error) do
    event_queue_item
    |> change(%{
      status: :dead_letter,
      processing_completed_at: DateTime.utc_now(),
      errors: build_errors(event_queue_item, error),
      next_retry_after: nil
    })
  end

  @spec schedule_retry_changeset(
          EventQueueItem.t(),
          any(),
          state(),
          non_neg_integer()
        ) :: Ecto.Changeset.t()
  def schedule_retry_changeset(event_queue_item, error, state, delay) do
    now = DateTime.utc_now()

    event_queue_item
    |> change(%{
      status: state,
      next_retry_after: DateTime.add(now, delay, :second),
      processor_id: nil,
      processing_completed_at: now,
      errors: build_errors(event_queue_item, error)
    })
  end

  @spec schedule_update_retry_changeset(
          EventQueueItem.t(),
          UpdateEventError.t(),
          non_neg_integer()
        ) :: Ecto.Changeset.t()
  def schedule_update_retry_changeset(
        event_queue_item,
        %UpdateEventError{
          create_event: create_event,
          message: message
        },
        retry_delay
      ) do
    now = DateTime.utc_now()

    %{event_queue_item: %{next_retry_after: ce_next_retry_after}} = create_event

    next_retry_after =
      DateTime.add(ce_next_retry_after || now, retry_delay, :second)

    event_queue_item
    |> change(
      status: :failed,
      processor_id: nil,
      processing_completed_at: now,
      next_retry_after: next_retry_after,
      errors: build_errors(event_queue_item, message)
    )
  end

  @spec build_errors(EventQueueItem.t(), any()) :: list(ErrorMap.error())
  defp build_errors(event_queue_item, error) do
    if is_nil(error) do
      event_queue_item.errors
    else
      [build_error(error) | event_queue_item.errors]
    end
  end
end
