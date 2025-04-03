defmodule DoubleEntryLedger.EventWorker.CreateEvent do
  @moduledoc """
  Provides helper functions for handling events with the `action: :create` attribute
  in the double-entry ledger system.
  """

  alias Ecto.Multi

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStore,
    EventStoreHelper,
    TransactionStore,
    Repo
  }

  import DoubleEntryLedger.OccRetry

  import DoubleEntryLedger.EventWorker.EventTransformer,
    only: [transaction_data_to_transaction_map: 2]

  @doc """
  Processes the event by transforming transaction data and creating a transaction.

  Given an `Event` struct, it transforms the embedded transaction data into a transaction map,
  then attempts to create a transaction within the ledger system. If the transformation and creation
  are successful, it returns `{:ok, transaction, event}`.

  It returns `{:error, reason}` if the transformation of transaction data to transaction map
  fails and sets the event status to `:failed`.

  In order to handle optimistic concurrency control (OCC) conflicts, it uses the
  `create_event_with_retry/4` function which implements retry logic.

  ## Parameters

    - `event`: An `Event` struct containing the transaction data to be processed.

  ## Returns

    - `{:ok, transaction, event}` on successful processing.
    - `{:error, reason}` if processing fails.
  """
  @spec process_create_event(Event.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_create_event(%Event{transaction_data: transaction_data, instance_id: id} = event) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        case process_create_event_with_retry(event, transaction_map, max_retries()) do
          {:ok, %{transaction: transaction, event: update_event}} ->
            {:ok, {transaction, update_event}}

          {:error, step, error, _} ->
            handle_error(event, "#{step} step failed: #{inspect(error)}")

          {:error, error} ->
            handle_error(event, "#{inspect(error)}")
        end

      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

  @doc """
  Attempts to process the event with the transaction map to create a transaction and update the event with retry logic.

  This function handles the creation of a transaction and updates the event accordingly.
  It implements retry logic to handle cases where optimistic concurrency control conflicts occur.
  If a `StaleEntryError` is encountered, it retries the operation until the maximum number of
  attempts is reached. If the maximum number of attempts is reached, it sets the event
  status as `:occ_timeout` and returns `{:error, reason}`.

  These retries are implemented with exponential backoff. An event wit the status `:occ_timeout`
  can be retried

  ## Parameters

    - `event`: The `Event` struct to be processed.
    - `transaction_map`: A map representing the transaction data.
    - `attempts`: The number of remaining attempts.
    - `repo`: (Optional) The Ecto repository module. Defaults to `Repo`.

  ## Returns

    - `{:ok, {transaction, event}}` if the transaction is successfully created.
    - `{:error, reason}` if the operation fails after all retries.
  """
  @spec process_create_event_with_retry(Event.t(), map(), integer(), Ecto.Repo.t()) ::
          {:ok, %{transaction: Transaction.t(), event: Event.t()}}
          | {:error, String.t()}
          | Multi.failure()
  def process_create_event_with_retry(event, transaction_map, attempts, repo \\ Repo)

  def process_create_event_with_retry(event, transaction_map, attempts, repo) when attempts > 0 do
    case build_create_transaction_and_update_event(event, transaction_map, repo)
         |> repo.transaction() do
      {:error, :transaction, %Ecto.StaleEntryError{}, %{}} ->
        {:ok, updated_event} = EventStore.add_error(event, occ_error_message(attempts))
        set_delay_timer(attempts)
        process_create_event_with_retry(updated_event, transaction_map, attempts - 1, repo)

      result ->
        result
    end
  end

  def process_create_event_with_retry(event, _transaction_map, 0, _repo) do
    EventStore.mark_as_occ_timeout(event, occ_final_error_message())
    {:error, occ_final_error_message()}
  end

  @spec build_create_transaction_and_update_event(Event.t(), map(), Ecto.Repo.t()) ::
          Ecto.Multi.t()
  defp build_create_transaction_and_update_event(event, transaction_map, repo) do
    Multi.new()
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStoreHelper.build_mark_as_processed(event, td.id)
    end)
  end

  defp handle_error(event, reason) do
    EventStore.mark_as_failed(event, reason)
    {:error, reason}
  end
end
