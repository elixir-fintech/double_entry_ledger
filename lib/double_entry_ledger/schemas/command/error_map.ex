defmodule DoubleEntryLedger.Command.ErrorMap do
  @moduledoc """
  Provides error tracking and management for command processing in the Double Entry Ledger system.

  This module defines the ErrorMap struct used to track errors, completed steps, and retry attempts
  during command processing, particularly when handling Optimistic Concurrency Control (OCC) conflicts.

  ## Structure

  The ErrorMap contains:

  * `errors`: List of error entries, each with a message and timestamp
  * `steps_so_far`: Map of steps that completed successfully before an error occurred
  * `retries`: Counter tracking the number of retry attempts made

  ## Key Functions

  * `build_error/2`: Creates a standardized error entry from various input types
  * `build_errors/2`: Adds a new error to an existing error list
  * `create_error_map/1`: Initializes an ErrorMap from a Command or TransactionCommandMap

  ## Usage Examples

  Creating an error map:

      error_map = ErrorMap.create_error_map(command)

  Adding an error:

      updated_errors = ErrorMap.build_errors(error_map.errors, "Transaction failed due to stale data")
      %{error_map | errors: updated_errors}

  ## Implementation Notes

  The ErrorMap is primarily used within the OCC processor to track retry attempts and preserve
  error contexts when a transaction fails due to concurrent modifications to the same data.
  """

  defstruct errors: [],
            steps_so_far: %{},
            retries: 0,
            save_on_error: false

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias __MODULE__, as: ErrorMap

  @typedoc """
  Represents a single error entry with a message and timestamp.

  Contains details about an error that occurred during command processing.

  ## Fields

  * `message`: A descriptive message about the error
  * `class`: The kind of failure, for telemetry; see `build_error/2`
  * `inserted_at`: DateTime when the error was recorded
  """
  @type error() :: %{
          message: String.t(),
          class: String.t(),
          inserted_at: DateTime.t()
        }

  @typedoc """
  The ErrorMap structure used for tracking errors during command processing.

  This is the main structure for tracking retry attempts, errors, and partial
  transaction results during optimistic concurrency control processing.

  ## Fields

  * `errors`: List of error entries, newest first
  * `steps_so_far`: Map of steps that completed successfully before an error occurred
  * `retries`: Number of retry attempts that have been made
  """
  @type t :: %ErrorMap{
          errors: list(error()) | [],
          steps_so_far: map(),
          retries: integer(),
          save_on_error: boolean()
        }

  @doc """
  Adds a new error to the beginning of an existing error list.

  Creates a standardized error entry from the provided message and prepends
  it to the existing list of errors.

  ## Parameters
    - `errors`: The existing list of errors
    - `error_message`: The error message or object to add

  ## Returns
    - The updated list of errors with the new error at the front

  ## Examples

      iex> alias DoubleEntryLedger.Command.ErrorMap
      iex> errors = []
      iex> updated_errors = ErrorMap.build_errors(errors, "Transaction failed")
      iex> length(updated_errors)
      1
  """
  @spec build_errors(list(error()), any()) :: list(error())
  def build_errors(errors, error_message) do
    [build_error(error_message) | errors]
  end

  @doc """
  Creates a standardized error entry from various input types.

  Converts any error representation into a standardized error map structure
  with a message and timestamp.

  ## Parameters
    - `error`: The error to standardize (string or any other type)
    - `inserted_at`: when the error was recorded (defaults to now)

  ## Returns
    - A standardized error map with message, class and timestamp

  ## Examples

      iex> alias DoubleEntryLedger.Command.ErrorMap
      iex> error = ErrorMap.build_error("Invalid amount")
      iex> is_map(error) and is_binary(error.message)
      true

      iex> alias DoubleEntryLedger.Command.ErrorMap
      iex> error = ErrorMap.build_error(%{reason: :not_found})
      iex> String.contains?(error.message, "not_found")
      true
  """
  @spec build_error(any(), DateTime.t()) :: error()
  def build_error(error, inserted_at \\ DateTime.utc_now(:microsecond))

  def build_error(error, inserted_at) when is_binary(error),
    do: entry(error, inserted_at)

  # Convert the error to a string representation. This is useful for
  # non-binary errors that may not have a direct string representation.
  def build_error(error, inserted_at), do: entry(inspect(error), inserted_at)

  defp entry(message, inserted_at),
    do: %{message: message, class: class(message), inserted_at: inserted_at}

  # The queue row and a telemetry event are not the same kind of sink, so the
  # message is split by destination rather than by content, once, here, where
  # the entry is built. `CommandQueue.Scheduling.emit_persisted_failure/3` then
  # reads `:class` as a field instead of re-deriving it from a sentence that
  # may have been reworded since.
  #
  # The COLUMN crosses no boundary. `commands.command_map` sits beside it and
  # `Command`'s Jason encoder serialises `command_map` and `command_queue_item`
  # together, so a payload fragment in the queue item's errors tells a reader
  # nothing the field next to it does not, and this is the column operators
  # actually read. The full message stays in `:message`.
  #
  # The EVENT does cross one. It reaches whatever exporter the host attached
  # and carries no payload of its own — `command_id`, `instance_id` and this
  # string — so the error text is the only route by which a fragment of a
  # command's payload could leave the database. A crashed task's reason reaches
  # here through `InstanceProcessor`'s crash retry (see
  # `CommandQueue.Cleanup.failure_shape/1`) and again when a takeover re-reads
  # the row. The event therefore carries the CLASS; a consumer that needs the
  # detail has the command id and can read the row, which puts the detail
  # behind database access.
  #
  # The class is everything before the FIRST `": "`, and taking only the first
  # segment is the safety property rather than a formatting choice: every
  # message this library persists is written `"<class>: <detail>"`, and a detail
  # can itself contain `": "` — a `MatchError`'s message is `"no match of right
  # hand side value: <term>"`. A rule that split on a later separator would
  # carry exactly the fragment this exists to stop. For the same reason the
  # crashing exception's own module stays on the row: it sits two segments deep,
  # behind `"Max retry count (N) exceeded: Task crashed: "`.
  @spec class(String.t()) :: String.t()
  defp class(message), do: message |> String.split(": ", parts: 2) |> hd()

  @doc """
  Initializes an ErrorMap from a Command or TransactionCommandMap.

  Creates a new ErrorMap structure, preserving any existing errors from the
  command while initializing other tracking fields.

  ## Parameters
    - `command`: Command or TransactionCommandMap to initialize from

  ## Returns
    - A new ErrorMap struct with initialized fields

  ## Examples

      iex> alias DoubleEntryLedger.Command.ErrorMap
      iex> alias DoubleEntryLedger.Command
      iex> command = %Command{command_queue_item: %{errors: [%{message: "Previous error", inserted_at: ~U[2023-01-01 00:00:00Z]}]}}
      iex> error_map = ErrorMap.create_error_map(command)
      iex> error_map.retries
      0
      iex> length(error_map.errors)
      1
  """
  @spec create_error_map(Command.t() | TransactionCommandMap.t()) :: t()
  def create_error_map(%Command{command_queue_item: command_queue_item}) do
    %ErrorMap{
      errors: Map.get(command_queue_item, :errors, []),
      steps_so_far: %{},
      retries: 0,
      save_on_error: true
    }
  end

  def create_error_map(_) do
    %ErrorMap{
      errors: [],
      steps_so_far: %{},
      retries: 0,
      save_on_error: true
    }
  end

  @spec changeset_errors(Ecto.Changeset.t()) :: String.t()
  def changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} ->
      "#{msg}"
    end)
    |> inspect()
  end
end
