defmodule DoubleEntryLedger.CommandQueueItem do
  @moduledoc """
  Schema for the command queue table, used for worker-based queue management.
  This schema tracks commands that need to be processed by workers.

  ## Database-managed columns

  PostgreSQL assigns `queue_position` once and owns `inserted_at`,
  `updated_at`, `processing_started_at`, and `processing_completed_at`. These
  fields are read back after writes; `changeset/2` does not cast an
  application-supplied queue position or processing timestamps.

  ## Retry deadlines

  PostgreSQL also computes `next_retry_after` (migration 5). Retry
  changesets write a `retry_delay_seconds` instruction instead of a
  timestamp; the queue trigger sets `next_retry_after` to the database clock
  plus that delay and clears `retry_delay_seconds` in the same write, so the
  column is always `NULL` at rest and no application clock is involved. Both
  columns are read back after writes.
  """

  use DoubleEntryLedger.BaseSchema
  import Ecto.Changeset
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError
  alias DoubleEntryLedger.Command.ErrorMap
  alias DoubleEntryLedger.{Command, Instance}
  import DoubleEntryLedger.Command.ErrorMap, only: [build_error: 1]

  alias __MODULE__, as: CommandQueueItem

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          status: state() | nil,
          processor_id: String.t() | nil,
          processor_version: integer() | nil,
          processing_started_at: DateTime.t() | nil,
          processing_completed_at: DateTime.t() | nil,
          retry_count: integer() | nil,
          next_retry_after: DateTime.t() | nil,
          retry_delay_seconds: non_neg_integer() | nil,
          occ_retry_count: integer() | nil,
          errors: list(map()) | nil,
          queue_position: integer() | nil,
          command_id: Ecto.UUID.t() | nil,
          instance_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # Keep lifecycle changes in the command-queue timestamp trigger in sync with
  # these states.
  @states [:pending, :processed, :failed, :occ_timeout, :processing, :dead_letter]
  @type state ::
          unquote(
            Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )

  @derive {Jason.Encoder,
           only: [:status, :processing_completed_at, :retry_count, :next_retry_after, :errors]}

  schema "command_queue_items" do
    field(:status, Ecto.Enum, values: @states, default: :pending)
    field(:processor_id, :string)
    field(:processor_version, :integer, default: 1)
    field(:processing_started_at, :utc_datetime_usec, read_after_writes: true)
    field(:processing_completed_at, :utc_datetime_usec, read_after_writes: true)
    field(:retry_count, :integer, default: 0)
    field(:next_retry_after, :utc_datetime_usec, read_after_writes: true)
    # Transient instruction to the queue trigger (migration 5); never
    # persisted, so it reads back as nil after every write.
    field(:retry_delay_seconds, :integer, read_after_writes: true)
    field(:occ_retry_count, :integer, default: 0)
    field(:errors, {:array, :map}, default: [])
    field(:queue_position, :integer, read_after_writes: true)

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
    field(:updated_at, :utc_datetime_usec, read_after_writes: true)

    belongs_to(:command, Command, type: Ecto.UUID)
    # Denormalized from `commands.instance_id` (migration 5) so the
    # `find_next_command` partial index can be keyed on
    # (instance_id, queue_position) without a JOIN.
    belongs_to(:instance, Instance, type: Ecto.UUID)
  end

  @doc false
  def changeset(command_queue_item, attrs) do
    command_queue_item
    |> cast(attrs, [
      :status,
      :processor_id,
      :processor_version,
      :retry_count,
      :next_retry_after,
      :occ_retry_count,
      :errors,
      :command_id,
      :instance_id
    ])
    |> validate_required([:status, :instance_id])
    |> validate_inclusion(:status, @states)
  end

  @doc """
  Marks the queue item `:processed` and clears its retry deadline, fenced on
  `processor_version`.
  """
  @spec processing_complete_changeset(CommandQueueItem.t()) :: Ecto.Changeset.t()
  def processing_complete_changeset(command_queue_item) do
    command_queue_item
    |> change(%{
      status: :processed,
      next_retry_after: nil
    })
    |> optimistic_lock(:processor_version)
  end

  @doc """
  Returns the queue item to `:pending` so it can be claimed again, recording
  `error` and fenced on `processor_version`.
  """
  @spec revert_to_pending_changeset(CommandQueueItem.t(), any()) :: Ecto.Changeset.t()
  def revert_to_pending_changeset(command_queue_item, error \\ nil) do
    command_queue_item
    |> change(%{
      status: :pending,
      errors: build_errors(command_queue_item, error)
    })
    |> optimistic_lock(:processor_version)
  end

  @doc """
  Marks the queue item `:dead_letter`, recording `error` and clearing its retry
  deadline, fenced on `processor_version`.
  """
  @spec dead_letter_changeset(CommandQueueItem.t(), any()) :: Ecto.Changeset.t()
  def dead_letter_changeset(command_queue_item, error) do
    command_queue_item
    |> change(%{
      status: :dead_letter,
      errors: build_errors(command_queue_item, error),
      next_retry_after: nil
    })
    |> optimistic_lock(:processor_version)
  end

  @doc """
  Schedules a retry `delay` seconds from now on the database clock.

  Writes `retry_delay_seconds`; the queue trigger computes `next_retry_after`
  from it, so the returned struct carries the database-produced deadline.
  """
  @spec schedule_retry_changeset(
          CommandQueueItem.t(),
          any(),
          state(),
          non_neg_integer()
        ) :: Ecto.Changeset.t()
  def schedule_retry_changeset(command_queue_item, error, state, delay) do
    command_queue_item
    |> change(%{
      status: state,
      retry_delay_seconds: delay,
      processor_id: nil,
      errors: build_errors(command_queue_item, error)
    })
    |> optimistic_lock(:processor_version)
  end

  @doc """
  Schedules the retry of an update command `retry_delay` seconds after its
  create command's own retry time.

  When the create command carries a `next_retry_after` (a database-produced
  value) the deadline is derived from it directly. Otherwise only
  `retry_delay_seconds` is written and the queue trigger computes
  `next_retry_after` on the database clock.
  """
  @spec schedule_update_retry_changeset(
          CommandQueueItem.t(),
          UpdateCommandError.t(),
          non_neg_integer()
        ) :: Ecto.Changeset.t()
  def schedule_update_retry_changeset(
        command_queue_item,
        %UpdateCommandError{
          create_command: %{command_queue_item: %{next_retry_after: create_next_retry_after}},
          message: message
        },
        retry_delay
      ) do
    command_queue_item
    |> change(
      status: :failed,
      processor_id: nil,
      errors: build_errors(command_queue_item, message)
    )
    |> change(retry_timing(create_next_retry_after, retry_delay))
    |> optimistic_lock(:processor_version)
  end

  @spec retry_timing(DateTime.t() | nil, non_neg_integer()) :: keyword()
  defp retry_timing(nil, retry_delay), do: [retry_delay_seconds: retry_delay]

  defp retry_timing(%DateTime{} = create_next_retry_after, retry_delay),
    do: [next_retry_after: DateTime.add(create_next_retry_after, retry_delay, :second)]

  @spec build_errors(CommandQueueItem.t(), any()) :: list(ErrorMap.error())
  defp build_errors(command_queue_item, error) do
    if is_nil(error) do
      command_queue_item.errors
    else
      [build_error(error) | command_queue_item.errors]
    end
  end
end
