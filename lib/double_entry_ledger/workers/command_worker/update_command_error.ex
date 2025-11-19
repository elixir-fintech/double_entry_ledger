defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError do
  @moduledoc """
  Custom exception for handling errors when update events can't be processed due to issues
  with their corresponding create events.

  This exception is raised when attempting to process an update event but the original create_command
  is either not found, pending, or failed. In the double-entry ledger system, update events
  modify existing entities, so they can only be processed after their create_commands have
  been successfully processed.

  ## Usage

  This exception is typically raised in the CommandWorker when processing an update event:

      iex> raise UpdateCommandError,
      ...>   update_command: update_command,
      ...>   create_command: create_command
      ** (UpdateCommandError) Create event (id: ...) not yet processed for Update Command (id: ...)

  ## Reasons

  The exception struct includes a `:reason` field, which can be one of:

    * `:create_command_not_processed` — The create event exists but is not yet processed (pending, processing, occ_timeout, or failed)
    * `:create_command_in_dead_letter` — The create event is in the dead letter state
    * `:create_command_not_found` — The create event could not be found

  ## Fields

    * `:message` — Human-readable error message
    * `:create_command` — The create event struct (may be `nil`)
    * `:update_command` — The update event struct
    * `:reason` — Atom describing the error reason

  ## Example

      try do
        # ...code that may raise UpdateCommandError...
      rescue
        e in UpdateCommandError ->
          IO.inspect(e.reason)
          IO.inspect(e.message)
      end
  """

  defexception [:message, :create_command, :update_command, :reason]

  alias DoubleEntryLedger.Command
  alias __MODULE__, as: UpdateCommandError

  @type t :: %__MODULE__{
          message: String.t(),
          create_command: Command.t() | nil,
          update_command: Command.t(),
          reason: atom()
        }

  @impl true
  def exception(opts) do
    update_command = Keyword.get(opts, :update_command)
    create_command = Keyword.get(opts, :create_command)

    case create_command do
      %{command_queue_item: %{status: :pending}} ->
        pending_error(create_command, update_command)

      %{command_queue_item: %{status: :processing}} ->
        pending_error(create_command, update_command)

      %{command_queue_item: %{status: :occ_timeout}} ->
        pending_error(create_command, update_command)

      %{command_queue_item: %{status: :failed}} ->
        pending_error(create_command, update_command)

      %{command_queue_item: %{status: :dead_letter}} ->
        %UpdateCommandError{
          message:
            "create Command (id: #{create_command.id}) in dead_letter for Update Command (id: #{update_command.id})",
          create_command: create_command,
          update_command: update_command,
          reason: :create_command_in_dead_letter
        }

      nil ->
        %UpdateCommandError{
          message: "create Command not found for Update Command (id: #{update_command.id})",
          create_command: nil,
          update_command: update_command,
          reason: :create_command_not_found
        }
    end
  end

  defp pending_error(
         %{command_queue_item: %{status: status}} = create_command,
         update_command
       ) do
    %UpdateCommandError{
      message:
        "create Command (id: #{create_command.id}, status: #{status}) not yet processed for Update Command (id: #{update_command.id})",
      create_command: create_command,
      update_command: update_command,
      reason: :create_command_not_processed
    }
  end
end
