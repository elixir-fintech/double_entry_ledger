defmodule DoubleEntryLedger.EventWorker.EventMap do
  @moduledoc """
  Provides functions to process event maps by creating event records and handling associated transactions.
  """

  alias DoubleEntryLedger.{
    CreateEvent,
    Event,
    EventStore,
    Transaction,
    Repo,
    UpdateEvent,
    OccRetry
  }

  alias DoubleEntryLedger.EventWorker.{CreateEvent, EventTransformer, UpdateEvent}
  alias Ecto.Multi
  import CreateEvent, only: [process_create_event_with_retry: 4]
  import UpdateEvent, only: [process_update_event: 1]
  import OccRetry, only: [max_retries: 0]
  import EventTransformer, only: [transaction_data_to_transaction_map: 2]

  @doc """
  Processes an event map using the default repository.

  ## Parameters
    - `event_map`: A map representing the event data.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_map(Event.event_map()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_map(event_map) do
    process_map(event_map, Repo)
  end

  @doc """
  Processes an event map by creating an event record and handling the associated transaction using the specified repository.

  ## Parameters
    - `event_map`: A map representing the event data.
    - `repo`: The repository to use for database operations.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_map(Event.event_map(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_map(%{transaction_data: transaction_data, instance_id: id} = event_map, repo) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        case build_process_event_map(event_map, transaction_map, repo) |> repo.transaction() do
          {:ok, %{process_event: %{transaction: transaction}, update_event: event}} ->
            {:ok, transaction, event}

          {:error, step, error, _} ->
            {:error, "#{step} failed: #{error}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec build_process_event_map(Event.event_map(), map(), Ecto.Repo.t()) ::
          Ecto.Multi.t()
  defp build_process_event_map(event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStore.build_insert_event(new_event_map))
    |> Multi.run(:process_event, fn _repo, %{create_event: new_event} ->
      # TODO: handle when transaction is not created, the event should be created and marked accordingly
      case new_event do
        %{action: :create} ->
          process_create_event_with_retry(new_event, transaction_map, max_retries(), repo)

        %{action: :update} ->
          case process_update_event(new_event) do
            {:ok, {transaction, event}} -> {:ok, %{transaction: transaction, event: event}}
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, "Event not created"}
      end
    end)
    |> Multi.update(:update_event, fn %{process_event: %{transaction: transaction, event: event}} ->
      EventStore.build_mark_as_processed(event, transaction.id)
    end)
  end
end
