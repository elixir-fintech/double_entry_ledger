defmodule DoubleEntryLedger.ProcessEvent do
  @moduledoc """
  Provides functions to process ledger events and handle transactions accordingly.
  """

  alias Ecto.Multi
  alias DoubleEntryLedger.Repo

  alias DoubleEntryLedger.{
    CreateEvent, Event, EventStore, Transaction, UpdateEvent
  }

  import CreateEvent, only: [process_create_event: 1]
  import UpdateEvent, only: [process_update_event: 1]

  @doc """
  Processes a pending event by executing its associated action.

  ## Parameters
    - event: The `%Event{}` struct to be processed.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event(Event.t()) :: {:ok, Transaction.t(), Event.t()} | {:error, binary()}
  def process_event(%Event{status: :pending, action: :create} = event) do
    process_create_event(event)
  end

  def process_event(%Event{status: :pending, action: :update} = event) do
    process_update_event(event)
  end

  def process_event(%Event{status: :pending, action: _} = _event) do
    {:error, "Action is not supported"}
  end

  def process_event(%Event{} = _event) do
    {:error, "Event is not in pending state"}
  end

  @doc """
  Processes an event map by creating an event record and handling the associated transaction.

  ## Parameters
    - event_map: A map representing the event data.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event_map(Event.event_map()) :: {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_event_map(%{} = event_map) do
    case build_process_event_map(event_map) |> Repo.transaction() do
      {:ok, %{process_event: {transaction, _}, update_event: event}} -> {:ok, transaction, event}
      {:error, step, error, _} -> {:error, "#{step} failed: #{error}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_process_event_map(Event.event_map()) :: Multi.t()
  defp build_process_event_map(event_map) do
    Multi.new()
    |> Multi.run(:create_event, fn _repo, _changes ->
      EventStore.insert_event(Map.put_new(event_map, :status, :pending))
    end)
    |> Multi.run(:process_event, fn _repo, %{create_event: new_event} ->
      case process_event(new_event) do
        {:ok, transaction, event} -> {:ok, {transaction, event}}
        {:error, reason} -> {:error, :process_event, reason}
      end
    end)
    |> Multi.run(:update_event, fn _repo, %{process_event: {transaction, event}} ->
      EventStore.mark_as_processed(event, transaction.id)
    end)
  end
end
