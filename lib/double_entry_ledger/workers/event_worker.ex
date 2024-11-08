defmodule DoubleEntryLedger.EventWorker do
  @moduledoc """
  Processes events to create and update Transactions
  that update the balances of accounts.

  Handles events with actions `:create` and `:update`, and updates the ledger accordingly.
  """
  alias Ecto.Multi
  alias DoubleEntryLedger.Repo

  alias DoubleEntryLedger.{
    CreateEvent, Event, EventStore, Transaction, UpdateEvent
  }

  import CreateEvent, only: [process_create_event: 1]
  import UpdateEvent, only: [process_update_event: 1]

  @doc """
  Processes an event by its UUID.

  Retrieves the event from the store and processes it based on its action.

  ## Parameters

    - `uuid`: The UUID of the event to process.

  ## Returns

    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event_with_id(Ecto.UUID.t()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_event_with_id(uuid) do
    case EventStore.get_event(uuid) do
      {:ok, event} -> process_event(event)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Processes an event based on its action and status.

  Accepts either an `%Event{}` struct or an event map.

  ## Parameters

    - `event`: The `%Event{}` struct or event map to be processed.

  ## Returns

    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event(Event.t() | Event.event_map()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_event(%Event{status: :pending, action: action } = event) do
    case action do
      :create -> process_create_event(event)
      :update -> process_update_event(event)
      _ -> {:error, "Action is not supported"}
    end
  end

  def process_event(%Event{} = _event) do
    {:error, "Event is not in pending state"}
  end

  def process_event(%{} = event_map)  do
    case process_new_event(event_map) do
      {:ok, %{process_event: transaction, update_event: event}} -> {:ok, transaction, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_new_event(event_map) do
    Multi.new()
    |> Multi.run(:create_event, fn _repo, _changes ->
      EventStore.insert_event(Map.put_new(event_map, :status, :pending))
    end)
    |> Multi.run(:process_event, fn _repo, %{create_event: event} ->
      case process_event(event) do
        {:ok, transaction, _} -> {:ok, transaction}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.run(:update_event, fn _repo, %{create_event: event, process_event: transaction} ->
      EventStore.mark_as_processed(event, transaction.id)
    end)
    |> Repo.transaction()
  end
end
