defmodule DoubleEntryLedger.EventWorker.AddUpdateEventError do
  @moduledoc """
  Custom exception for handling errors when update events can't be processed due to issues
  with their corresponding create events.

  This exception is raised when attempting to process an update event but the original create_transaction event
  is either not found, pending, or failed. In the double-entry ledger system, update events
  modify existing transactions, so they can only be processed after their create_transaction events have
  been successfully processed.

  ## Usage

  This exception is typically raised in the EventWorker when processing an update event:

      iex> raise AddUpdateEventError,
      ...>   update_event: update_event,
      ...>   create_transaction_event: create_transaction_event
      ** (AddUpdateEventError) Create event (id: ...) not yet processed for Update Event (id: ...)

  ## Reasons

  The exception struct includes a `:reason` field, which can be one of:

    * `:create_transaction_event_not_processed` — The create_transaction event exists but is not yet processed (pending, processing, occ_timeout, or failed)
    * `:create_transaction_event_in_dead_letter` — The create_transaction event is in the dead letter state
    * `:create_transaction_event_not_found` — The create_transaction event could not be found

  ## Fields

    * `:message` — Human-readable error message
    * `:create_transaction_event` — The create_transaction event struct (may be `nil`)
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

  defexception [:message, :create_transaction_event, :update_event, :reason]

  alias DoubleEntryLedger.Event
  alias __MODULE__, as: AddUpdateEventError

  @type t :: %__MODULE__{
          message: String.t(),
          create_transaction_event: Event.t() | nil,
          update_event: Event.t(),
          reason: atom()
        }

  @impl true
  def exception(opts) do
    update_event = Keyword.get(opts, :update_event)
    create_transaction_event = Keyword.get(opts, :create_transaction_event)

    case create_transaction_event do
      %{event_queue_item: %{status: :pending}} ->
        pending_error(create_transaction_event, update_event)

      %{event_queue_item: %{status: :processing}} ->
        pending_error(create_transaction_event, update_event)

      %{event_queue_item: %{status: :occ_timeout}} ->
        pending_error(create_transaction_event, update_event)

      %{event_queue_item: %{status: :failed}} ->
        pending_error(create_transaction_event, update_event)

      %{event_queue_item: %{status: :dead_letter}} ->
        %AddUpdateEventError{
          message:
            "create_transaction Event (id: #{create_transaction_event.id}) in dead_letter for Update Event (id: #{update_event.id})",
          create_transaction_event: create_transaction_event,
          update_event: update_event,
          reason: :create_transaction_event_in_dead_letter
        }

      nil ->
        %AddUpdateEventError{
          message: "create_transaction Event not found for Update Event (id: #{update_event.id})",
          create_transaction_event: nil,
          update_event: update_event,
          reason: :create_transaction_event_not_found
        }
    end
  end

  defp pending_error(
         %{event_queue_item: %{status: status}} = create_transaction_event,
         update_event
       ) do
    %AddUpdateEventError{
      message:
        "create_transaction Event (id: #{create_transaction_event.id}, status: #{status}) not yet processed for Update Event (id: #{update_event.id})",
      create_transaction_event: create_transaction_event,
      update_event: update_event,
      reason: :create_transaction_event_not_processed
    }
  end
end
