defmodule DoubleEntryLedger.CreateEvent do
  @moduledoc """
  Provides helper functions for creating events in the double-entry ledger system.
  """

  alias Ecto.Multi

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStore,
    TransactionStore,
    Repo
  }

  import DoubleEntryLedger.OccRetry
  import DoubleEntryLedger.EventTransformer, only: [transaction_data_to_transaction_map: 2]

  @doc """
  Processes the creation of an event by transforming transaction data and creating a transaction.

  Returns `{:ok, transaction, event}` on success, or `{:error, reason}` on failure.
  """
  @spec process_create_event(Event.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_create_event(%Event{transaction_data: transaction_data, instance_id: id} = event) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        create_event_with_retry(event, transaction_map, max_retries())

      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

  @spec create_event_with_retry(Event.t(), map(), integer()) ::
          {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  def create_event_with_retry(event, transaction_map, attempts) when attempts > 0 do
    try do
      create_transaction_and_update_event(event, transaction_map)
    rescue
      Ecto.StaleEntryError ->
        {:ok, updated_event} = EventStore.add_error(event, occ_error_message(attempts))
        set_delay_timer(attempts)
        create_event_with_retry(updated_event, transaction_map, attempts - 1)
    end
  end

  def create_event_with_retry(_event, _transaction_map, 0) do
    {:error, occ_final_error_message()}
  end

  @spec create_transaction_and_update_event(Event.t(), map()) ::
          {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  defp create_transaction_and_update_event(event, transaction_map) do
    case build_create_transaction_and_update_event(event, transaction_map)
         |> Repo.transaction() do
      {:ok, %{transaction: transaction, event: update_event}} ->
        {:ok, {transaction, update_event}}

      {:error, step, error, _} ->
        {:error, "#{step} failed: #{error}"}

      {:error, error} ->
        {:error, "#{error}"}
    end
  end

  @spec build_create_transaction_and_update_event(Event.t(), map()) :: Ecto.Multi.t()
  defp build_create_transaction_and_update_event(event, transaction_map) do
    Multi.new()
    |> TransactionStore.build_create(:transaction, transaction_map)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStore.build_mark_as_processed(event, td.id)
    end)
  end
end
