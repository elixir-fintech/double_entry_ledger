defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateEventError do
  @moduledoc """
  Custom exception for handling errors when update events can't be processed due to issues
  with their corresponding create events.

  This exception is raised when attempting to process an update event but the original create_event
  is either not found, pending, or failed. In the double-entry ledger system, update events
  modify existing entities, so they can only be processed after their create_events have
  been successfully processed.

  ## Usage

  This exception is typically raised in the CommandWorker when processing an update event:

      iex> raise UpdateEventError,
      ...>   update_event: update_event,
      ...>   create_event: create_event
      ** (UpdateEventError) Create event (id: ...) not yet processed for Update Command (id: ...)

  ## Reasons

  The exception struct includes a `:reason` field, which can be one of:

    * `:create_event_not_processed` — The create event exists but is not yet processed (pending, processing, occ_timeout, or failed)
    * `:create_event_in_dead_letter` — The create event is in the dead letter state
    * `:create_event_not_found` — The create event could not be found

  ## Fields

    * `:message` — Human-readable error message
    * `:create_event` — The create event struct (may be `nil`)
    * `:update_event` — The update event struct
    * `:reason` — Atom describing the error reason

  ## Example

      try do
        # ...code that may raise UpdateEventError...
      rescue
        e in UpdateEventError ->
          IO.inspect(e.reason)
          IO.inspect(e.message)
      end
  """

  defexception [:message, :create_event, :update_event, :reason]

  alias DoubleEntryLedger.Command
  alias __MODULE__, as: UpdateEventError

  @type t :: %__MODULE__{
          message: String.t(),
          create_event: Command.t() | nil,
          update_event: Command.t(),
          reason: atom()
        }

  @impl true
  def exception(opts) do
    update_event = Keyword.get(opts, :update_event)
    create_event = Keyword.get(opts, :create_event)

    case create_event do
      %{command_queue_item: %{status: :pending}} ->
        pending_error(create_event, update_event)

      %{command_queue_item: %{status: :processing}} ->
        pending_error(create_event, update_event)

      %{command_queue_item: %{status: :occ_timeout}} ->
        pending_error(create_event, update_event)

      %{command_queue_item: %{status: :failed}} ->
        pending_error(create_event, update_event)

      %{command_queue_item: %{status: :dead_letter}} ->
        %UpdateEventError{
          message:
            "create Command (id: #{create_event.id}) in dead_letter for Update Command (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_in_dead_letter
        }

      nil ->
        %UpdateEventError{
          message: "create Command not found for Update Command (id: #{update_event.id})",
          create_event: nil,
          update_event: update_event,
          reason: :create_event_not_found
        }
    end
  end

  defp pending_error(
         %{command_queue_item: %{status: status}} = create_event,
         update_event
       ) do
    %UpdateEventError{
      message:
        "create Command (id: #{create_event.id}, status: #{status}) not yet processed for Update Command (id: #{update_event.id})",
      create_event: create_event,
      update_event: update_event,
      reason: :create_event_not_processed
    }
  end
end
