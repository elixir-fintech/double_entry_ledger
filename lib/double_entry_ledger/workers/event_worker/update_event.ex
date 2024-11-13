defmodule DoubleEntryLedger.UpdateEvent do
  @moduledoc """
  Provides helper functions for updating events in the double-entry ledger system.
  """
  alias Ecto.Multi
  alias DoubleEntryLedger.{
    Event, Transaction, EventStore, TransactionStore, Repo
  }


  import DoubleEntryLedger.OccRetry
  import DoubleEntryLedger.EventTransformer, only: [transaction_data_to_transaction_map: 2]

  @doc """
  Processes the update of an event by fetching the corresponding transaction and applying updates.

  Returns `{:ok, transaction, event}` on success, or `{:error, reason}` on failure.
  """
  @spec process_update_event(Event.t()) :: {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  def process_update_event(event) do
    case fetch_create_event_transaction(event) do
      {:ok, {transaction, _}} ->
        update_transaction_and_event(event, transaction)
      {:pending_error, error, _} ->
        EventStore.add_error(event, error)
        {:error, error}
      {:error, error, _} ->
        {:error, error}
    end
  end

  @spec fetch_create_event_transaction(Event.t()) ::
    {:ok, {Transaction.t(), Event.t()}} | {(:error | :pending_error), String.t(), (Event.t() | nil)}
  defp fetch_create_event_transaction(%{id: e_id, source: source, source_idempk: source_idempk, instance_id: id}) do
    case EventStore.get_create_event_by_source(source, source_idempk, id) do
      %{processed_transaction: %{id: _} = transaction} = event ->
        {:ok, {transaction, event}}
      %{id: id, status: :pending} = event ->
        {:pending_error, "Create event (id: #{id}) has not yet been processed", event}
      %{id: id, status: :failed} = event ->
        {:error, "Create event (id: #{id}) has failed for Update Event (id: #{e_id})", event}
      nil ->
        {:error, "Create Event not found for Update Event (id: #{e_id})", nil}
    end
  end

  @spec update_transaction_and_event(Event.t(), Transaction.t()) ::
    {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  defp update_transaction_and_event(%{instance_id: id, transaction_data: td} = event, transaction) do
    case transaction_data_to_transaction_map(td, id) do
      {:ok, transaction_map} ->
        update_event(event, transaction, transaction_map)
      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

  @spec update_transaction_and_event(Event.t(), Transaction.t(), map()) ::
    {:ok, {Transaction.t(), Event.t()}} | {:error, String.t()}
  defp update_transaction_and_event(event, transaction, attrs) do
    case build_update_transaction_and_event(transaction, event, attrs) |> Repo.transaction() do
      {:ok, %{
        transaction: transaction,
        event: update_event}} ->
        {:ok, {transaction, update_event}}
      {:error, step, error, _} -> {:error, "#{step} failed: #{error}"}
      {:error, error} -> {:error, error}
    end
  end

  @spec build_update_transaction_and_event(Transaction.t(), Event.t(), map()) :: Ecto.Multi.t()
  defp build_update_transaction_and_event(transaction, event, attr) do
    Multi.new()
    |> TransactionStore.build_update(:transaction, transaction, attr)
    |> Multi.update(:event, fn %{transaction: td} ->
        EventStore.build_mark_as_processed(event, td.id)
      end)
  end

  def update_event(event, transaction, transaction_map) do
    retry_update_event(event, transaction, transaction_map, max_retries())
  end

  def retry_update_event(event, transaction, transaction_map, attempts) when attempts > 0 do
    try do
      update_transaction_and_event(event, transaction, transaction_map)
    rescue
      Ecto.StaleEntryError ->
        {:ok, updated_event} = EventStore.add_error(event, occ_error_message(attempts))
        set_delay_timer(attempts)
        retry_update_event(updated_event, transaction, transaction, attempts - 1)
    end
  end

  def retry_update_event(_event, _transaction, _transaction_map, 0) do
    {:error, occ_final_error_message()}
  end
end
