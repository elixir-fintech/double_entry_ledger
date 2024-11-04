defmodule DoubleEntryLedger.CreateEvent do
  @moduledoc """
  Helper functions for creating events.
  """

  alias Ecto.Multi
  alias DoubleEntryLedger.{
    Event, Transaction, EventStore, TransactionStore, Repo
  }

  import DoubleEntryLedger.OccRetry, only: [retry: 3]
  import DoubleEntryLedger.EventHelper, only: [transaction_data_to_transaction_map: 2]

  @spec process_create_event(Event.t()) :: {:ok, Transaction.t(), Event.t() } | {:error, String.t()}
  def process_create_event(%Event{transaction_data: transaction_data, instance_id: id} = event) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        retry(&create_transaction_and_update_event/2, event, transaction_map)
      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

  @spec create_transaction_and_update_event(Event.t(), map()) :: {:ok, Transaction.t(), Event.t()} | {:error, any()}
  defp create_transaction_and_update_event(event, transaction_map) do
    case build_create_transaction_and_update_event(event, transaction_map)
    |> Repo.transaction() do
      {:ok, %{
        create_transaction: %{transaction: transaction},
        update_event: update_event}} ->
        {:ok, transaction, update_event}
      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

  @spec build_create_transaction_and_update_event(Event.t(), map()) :: Ecto.Multi.t()
  defp build_create_transaction_and_update_event(event, transaction_map) do
    Multi.new()
    |> Multi.run(:create_transaction, fn repo, _ ->
        TransactionStore.build_create(transaction_map)
        |> repo.transaction()
      end)
    |> Multi.run(:update_event, fn repo, %{create_transaction: %{transaction: td}} ->
        EventStore.build_mark_as_processed(event, td.id)
        |> repo.update()
      end)
  end
end
