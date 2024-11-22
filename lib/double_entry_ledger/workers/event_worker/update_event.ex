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
  alias Ecto.{Multi, StaleEntryError}

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStore,
    TransactionStore,
    Repo
  }
  alias DoubleEntryLedger.EventStore.CreateEventError

  import DoubleEntryLedger.OccRetry

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
  @spec process_update_event(Event.t()) ::
          {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  def process_update_event(%{instance_id: id, transaction_data: td} = event) do
    case transaction_data_to_transaction_map(td, id) do
      {:ok, transaction_map} ->
        case process_update_event_with_retry(event, transaction_map, max_retries()) do
          {:ok, %{transaction: transaction, event: update_event}} ->
            {:ok, {transaction, update_event}}

          {:error, _step, %CreateEventError{reason: :create_event_pending} = error, _} ->
            EventStore.add_error(event, error.message)
            {:error, error.message}

          {:error, _step, %CreateEventError{} = error, _} ->
            handle_error(event, error.message)

          {:error, step, error, _} ->
            handle_error(event, "#{step} step failed: #{inspect(error)}")

          {:error, error} ->
            handle_error(event, inspect(error))
        end

      {:error, error} ->
        handle_error(event, inspect(error))
    end
  end

  @spec process_update_event_with_retry(Event.t(), map(), integer(), Ecto.Repo.t()
        ) :: {:ok, %{transaction: Transaction.t(), event: Event.t()}}
          | {:error, String.t()}
          | Multi.failure()
  def process_update_event_with_retry(event, transaction_map, attempts, repo \\ Repo)

  def process_update_event_with_retry(event, transaction_map, attempts, repo)
      when attempts > 0 do
    case build_update_transaction_and_event(event, transaction_map, repo)
         |> repo.transaction() do
      {:error, :transaction, %StaleEntryError{}, _} ->
        {:ok, updated_event} = EventStore.add_error(event, occ_error_message(attempts))
        set_delay_timer(attempts)

        process_update_event_with_retry(updated_event, transaction_map, attempts - 1, repo)

      result ->
        result
    end
  end

  def process_update_event_with_retry(event, _transaction_map, 0, _repo) do
    EventStore.mark_as_occ_timeout(event, occ_final_error_message())
    {:error, occ_final_error_message()}
  end

  @spec build_update_transaction_and_event(Event.t(), map(), Ecto.Repo.t()) ::
          Multi.t()
  defp build_update_transaction_and_event(event, attr, repo) do
    Multi.new()
    |> EventStore.build_get_create_event_transaction(:get_create_event_transaction, event)
    |> TransactionStore.build_update2(:transaction, :get_create_event_transaction, attr, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStore.build_mark_as_processed(event, td.id)
    end)
  end

  defp handle_error(event, reason) do
    EventStore.mark_as_failed(event, reason)
    {:error, reason}
  end
end
