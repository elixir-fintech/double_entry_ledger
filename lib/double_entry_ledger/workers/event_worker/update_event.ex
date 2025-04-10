defmodule DoubleEntryLedger.EventWorker.UpdateEvent do
  @moduledoc """
  Handles processing of existing events with the
  `action: :update` attribute in the double-entry ledger system.

  ## Functions

    * `process_update_event/1` - Processes an update event by fetching the corresponding transaction and applying updates.
    * `fetch_create_event_transaction/1` - Fetches the create event transaction associated with a given update event.
    * `update_transaction_and_event/2` - Updates the transaction and event based on the update event data.
    * `process_update_event_with_retry/5` - Processes the update event with retry logic in case of concurrency conflicts.

  """

  use DoubleEntryLedger.OccProcessor

  alias Ecto.Changeset
  alias Ecto.Multi

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStore,
    EventStoreHelper,
    TransactionStore,
    Repo
  }

  alias DoubleEntryLedger.EventWorker.AddUpdateEventError

  import DoubleEntryLedger.EventWorker.EventTransformer,
    only: [transaction_data_to_transaction_map: 2]

  @doc """
  Processes an update event by fetching the corresponding transaction and applying updates.

  ## Parameters

    - `event`: The `%Event{}` struct representing the update event to process.

  ## Returns

    - `{:ok, {transaction, event}}` on success.
    - `{:error, reason}` on failure.

  """
  @spec process_update_event(Event.t(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process_update_event(%{instance_id: id, transaction_data: td} = event, repo \\ Repo) do
    case transaction_data_to_transaction_map(td, id) do
      {:ok, transaction_map} ->
        case process_with_retry(event, transaction_map, max_retries(), repo) do
          {:ok, %{transaction: transaction, event: update_event}} ->
            {:ok, transaction, update_event}

          {:error, _step, %AddUpdateEventError{reason: :create_event_pending, message: message},
           _} ->
            add_error(event, message)

          {:error, _step, %AddUpdateEventError{} = error, _} ->
            handle_error(event, error.message)

          {:error, :transaction, :occ_final_timeout, event} ->
            {:error, event}

          {:error, step, error, _} ->
            handle_error(event, "#{step} step failed: #{inspect(error)}")

          {:error, error} ->
            handle_error(event, inspect(error))
        end

      {:error, error} ->
        handle_error(event, inspect(error))
    end
  end

  @impl true
  def build_transaction(event, attr, repo) do
    Multi.new()
    |> EventStoreHelper.build_get_create_event_transaction(:get_create_event_transaction, event)
    |> TransactionStore.build_update(:transaction, :get_create_event_transaction, attr, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStoreHelper.build_mark_as_processed(event, td.id)
    end)
  end

  @impl true
  def stale_error_handler(event, attempts, _error_map) do
    {:ok, updated_event} = EventStore.add_error(event, occ_error_message(attempts))
    updated_event
  end

  @impl true
  def finally(event, _) do
    {:ok, updated_event} = EventStore.mark_as_occ_timeout(event, occ_final_error_message())
    {:error, :transaction, :occ_final_timeout, updated_event}
  end

  @spec add_error(Event.t(), String.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  defp add_error(event, reason) do
    case EventStore.add_error(event, reason) do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec handle_error(Event.t(), String.t()) ::
          {:error, Event.t()} | {:error, Changeset.t()}
  defp handle_error(event, reason) do
    case EventStore.mark_as_failed(event, reason) do
      {:ok, event} ->
        {:error, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
