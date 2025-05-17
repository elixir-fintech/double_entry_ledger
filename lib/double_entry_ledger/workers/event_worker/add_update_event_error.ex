defmodule DoubleEntryLedger.EventWorker.AddUpdateEventError do
  @moduledoc """
  Custom exception for handling errors when update events can't be processed due to issues
  with their corresponding create events.

  This exception is raised when attempting to process an update event but the original create event
  is either not found, pending, or failed. In the double-entry ledger system, update events
  modify existing transactions, so they can only be processed after their create events have
  been successfully processed.

  ## Usage

  This exception is typically raised in the EventWorker when processing an update event:

      iex> raise AddUpdateEventError,
      ...>   update_event: update_event,
      ...>   create_event: create_event
      ** (AddUpdateEventError) Create event (id: ...) not yet processed for Update Event (id: ...)

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
        # ...code that may raise AddUpdateEventError...
      rescue
        e in AddUpdateEventError ->
          IO.inspect(e.reason)
          IO.inspect(e.message)
      end
  """

  defexception [:message, :create_event, :update_event, :reason]

  alias DoubleEntryLedger.Event
  alias __MODULE__, as: AddUpdateEventError

  @type t :: %__MODULE__{
          message: String.t(),
          create_event: Event.t() | nil,
          update_event: Event.t(),
          reason: atom()
        }

  @impl true
  def exception(opts) do
    update_event = Keyword.get(opts, :update_event)
    create_event = Keyword.get(opts, :create_event)

    case create_event do
      %Event{status: :pending} ->
        pending_error(create_event, update_event)

      %Event{status: :processing} ->
        pending_error(create_event, update_event)

      %Event{status: :occ_timeout} ->
        pending_error(create_event, update_event)

      %Event{status: :failed} ->
        pending_error(create_event, update_event)

      %Event{status: :dead_letter} ->
        %AddUpdateEventError{
          message:
            "Create event (id: #{create_event.id}) in dead_letter for Update Event (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_in_dead_letter
        }

      nil ->
        %AddUpdateEventError{
          message: "Create Event not found for Update Event (id: #{update_event.id})",
          create_event: nil,
          update_event: update_event,
          reason: :create_event_not_found
        }
    end
  end

  defp pending_error(create_event, update_event) do
    %AddUpdateEventError{
      message:
        "Create event (id: #{create_event.id}, status: #{create_event.status}) not yet processed for Update Event (id: #{update_event.id})",
      create_event: create_event,
      update_event: update_event,
      reason: :create_event_not_processed
    }
  end
end
