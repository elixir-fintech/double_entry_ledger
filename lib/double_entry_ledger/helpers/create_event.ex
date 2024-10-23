defmodule DoubleEntryLedger.CreateEvent do
  @moduledoc """
  Helper functions for creating events.
  """

  alias Ecto.Multi
  alias DoubleEntryLedger.{
    Event, Transaction, EventStore, TransactionStore, Repo
  }

  @spec create_transaction_and_update_event(Event.t(), map()) ::
    {:ok, Transaction.t(), Event.t()} | {:error, any()}
  def create_transaction_and_update_event(event, transaction_map) do
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

  def build_create_transaction_and_update_event(event, transaction_map) do
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
