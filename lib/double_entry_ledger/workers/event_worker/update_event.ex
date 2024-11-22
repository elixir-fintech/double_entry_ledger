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
  alias Ecto.Multi

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
  def process_update_event(event) do
    try do
      {:ok, {transaction, _}} = EventStore.get_create_event_transaction(event)
      update_transaction_and_event(event, transaction)
    rescue
      e in CreateEventError ->
      case e.reason do
        :create_event_pending ->
          {:pending_error, e.message, e.update_event}

        :create_event_failed ->
          {:error, e.message, e.update_event}

        :create_event_not_found ->
          {:error, e.message, e.update_event}
      end
    end
  end

  @doc """
  Updates the transaction and event based on the update event data.

  Converts the transaction data into a map suitable for updating the transaction, then processes the
  update with retry logic to handle any concurrency conflicts.

  ## Parameters

    - `event`: The `%Event{}` struct representing the update event.
    - `transaction`: The `%Transaction{}` struct that needs to be updated.

  ## Returns

    - `{:ok, {transaction, event}}` on success.
    - `{:error, reason}` on failure.

  """
  @spec update_transaction_and_event(Event.t(), Transaction.t()) ::
          {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  def update_transaction_and_event(%{instance_id: id, transaction_data: td} = event, transaction) do
    case transaction_data_to_transaction_map(td, id) do
      {:ok, transaction_map} ->
        case process_update_event_with_retry(event, transaction, transaction_map, max_retries()) do
          {:ok, %{transaction: transaction, event: update_event}} ->
            {:ok, {transaction, update_event}}

          {:error, step, error, _} ->
            handle_error(event, "#{step} step failed: #{inspect(error)}")

          {:error, error} ->
            handle_error(event, inspect(error))
        end

      {:error, error} ->
        handle_error(event, inspect(error))
    end
  end

  @doc """
  Processes the update event with retry logic in case of concurrency conflicts.

  Attempts to update the transaction and event within a database transaction.
  If a concurrency conflict occurs, such as an `Ecto.StaleEntryError`, it retries the operation up to
  the maximum number of attempts.

  ## Parameters

    - `event`: The `%Event{}` struct representing the update event.
    - `transaction`: The `%Transaction{}` struct to be updated.
    - `transaction_map`: A map containing the updated transaction attributes.
    - `attempts`: The number of remaining retry attempts.
    - `repo`: (Optional) The repository module to use for database operations. Defaults to `Repo`.

  ## Returns

    - `{:ok, %{transaction: transaction, event: event}}` on success.
    - `{:error, reason}` on failure.
    - `Multi.failure()` in case of transaction failure.

  """
  @spec process_update_event_with_retry(
          Event.t(),
          Transaction.t(),
          map(),
          integer(),
          Ecto.Repo.t()
        ) ::
          {:ok, %{transaction: Transaction.t(), event: Event.t()}}
          | {:error, String.t()}
          | Multi.failure()
  def process_update_event_with_retry(event, transaction, transaction_map, attempts, repo \\ Repo)

  def process_update_event_with_retry(event, transaction, transaction_map, attempts, repo)
      when attempts > 0 do
    case build_update_transaction_and_event(transaction, event, transaction_map, repo)
         |> repo.transaction() do
      {:error, :transaction, %Ecto.StaleEntryError{}, _} ->
        {:ok, updated_event} = EventStore.add_error(event, occ_error_message(attempts))
        set_delay_timer(attempts)

        process_update_event_with_retry(
          updated_event,
          transaction,
          transaction_map,
          attempts - 1,
          repo
        )

      result ->
        result
    end
  end

  def process_update_event_with_retry(event, _transaction, _transaction_map, 0, _repo) do
    EventStore.mark_as_occ_timeout(event, occ_final_error_message())
    {:error, occ_final_error_message()}
  end

  @spec build_update_transaction_and_event(Transaction.t(), Event.t(), map(), Ecto.Repo.t()) ::
          Multi.t()
  defp build_update_transaction_and_event(transaction, event, attr, repo) do
    Multi.new()
    |> EventStore.build_get_create_event_transaction(:create_event_transaction, event)
    |> TransactionStore.build_update2(:transaction, :create_event_transaction, attr, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStore.build_mark_as_processed(event, td.id)
    end)
  end

  defp handle_error(event, reason) do
    EventStore.mark_as_failed(event, reason)
    {:error, reason}
  end
end
