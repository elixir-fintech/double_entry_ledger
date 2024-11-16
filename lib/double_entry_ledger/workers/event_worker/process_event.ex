defmodule DoubleEntryLedger.ProcessEvent do
  @moduledoc """
  Provides functions to process ledger events and handle transactions accordingly.
  """

  alias DoubleEntryLedger.OccRetry
  alias Ecto.Multi
  alias DoubleEntryLedger.Repo

  alias DoubleEntryLedger.{
    CreateEvent, Event, EventStore, Transaction, UpdateEvent
  }

  import CreateEvent, only: [process_create_event: 1, process_create_event_with_retry: 4]
  import UpdateEvent, only: [process_update_event: 1]
  import OccRetry, only: [max_retries: 0]
  import DoubleEntryLedger.EventTransformer, only: [transaction_data_to_transaction_map: 2]

  @doc """
  Processes a pending event by executing its associated action.

  ## Parameters
    - event: The `%Event{}` struct to be processed.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_event(Event.t()) :: {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
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
  def process_event_map(%{transaction_data: transaction_data, instance_id: id} = event_map) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        case build_process_event_map(event_map, transaction_map) |> Repo.transaction() do
          {:ok, %{process_event: %{transaction: transaction}, update_event: event}} -> {:ok, transaction, event}
          {:error, step, error, _} -> {:error, "#{step} failed: #{error}"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec build_process_event_map(Event.event_map(), map(), Repo.t()) :: Multi.t()
  defp build_process_event_map(event_map, transaction_map, repo \\ Repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)
    Multi.new()
    |> Multi.insert(:create_event, EventStore.build_insert_event(new_event_map))
    |> Multi.run(:process_event, fn _repo, %{create_event: new_event} ->
      #TODO: handle when transaction is not created, the event should be created and marked accordingly
      case new_event do
        %{action: :create} ->
          process_create_event_with_retry(new_event, transaction_map, max_retries(), repo)
        %{action: :update} ->
          case process_event(new_event) do
            {:ok, {transaction, event}} -> {:ok, %{transaction: transaction, event: event}}
            {:error, reason} -> {:error, reason}
          end
        _ -> {:error, "Event not created"}
      end
    end)
    |> Multi.update(:update_event, fn %{process_event: %{transaction: transaction, event: event}} ->
      EventStore.build_mark_as_processed(event, transaction.id)
    end)
  end
end
