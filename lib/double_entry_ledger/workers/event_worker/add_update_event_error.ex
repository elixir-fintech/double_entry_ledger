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

  ```elixir
  def process_update_event(%{action: :update} = event_map) do
    # If we can't find the create event or it's in an invalid state
    if create_event.status == :pending do
      raise AddUpdateEventError,
        update_event: update_event,
        create_event: create_event
    end
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
        %AddUpdateEventError{
          message:
            "Create event (id: #{create_event.id}) has not yet been processed for Update Event (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_pending
        }

      %Event{status: :failed} ->
        %AddUpdateEventError{
          message:
            "Create event (id: #{create_event.id}) has failed for Update Event (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_failed
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
end
