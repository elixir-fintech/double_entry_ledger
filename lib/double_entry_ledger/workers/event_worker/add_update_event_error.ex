defmodule DoubleEntryLedger.EventWorker.AddUpdateEventError do
  defexception [:message, :create_event, :update_event, :reason]

  alias DoubleEntryLedger.Event
  alias __MODULE__, as: AddUpdateEventError

  @impl true
  def exception(opts) do
    update_event = Keyword.get(opts, :update_event)
    create_event = Keyword.get(opts, :create_event)
    case create_event do
      %Event{status: :pending} ->
        %AddUpdateEventError{
          message: "Create event (id: #{create_event.id}) has not yet been processed for Update Event (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_pending}
      %Event{status: :failed} ->
        %AddUpdateEventError{
          message: "Create event (id: #{create_event.id}) has failed for Update Event (id: #{update_event.id})",
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
