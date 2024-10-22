defmodule DoubleEntryLedger.EventProcessor do
  @moduledoc """
  This module processes events and updates the balances of the accounts
  """

  alias DoubleEntryLedger.EventProcessor
  alias DoubleEntryLedger.Repo
  alias Ecto.Multi
  alias DoubleEntryLedger.{
    Event, EventStore, Transaction, TransactionStore
  }

  import DoubleEntryLedger.EventHelper

  @max_retries Application.compile_env(:double_entry_ledger, :max_retries, 5)
  @retry_interval Application.compile_env(:double_entry_ledger, :retry_interval, 200)

  @spec process_event(Event.t()) :: {:ok, Transaction.t()} | {:error, String.t()}
  def process_event(%Event{status: :pending, action: action } = event) do
    case action do
      :create -> process_create_event(event)
      :update -> update_transaction(event)
      _ -> {:error, "Action is not supported"}
    end
  end

  def process_event(_event) do
    {:error, "Event is not in pending state"}
  end

  @spec process_create_event(Event.t()) :: {:ok, Transaction.t(), Event.t() } | {:error, String.t()}
  def process_create_event(%Event{transaction_data: transaction_data, instance_id: id} = event) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        retry(&EventProcessor.create_transaction_and_update_event/2, @max_retries, {event, transaction_map})
      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

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

  def update_transaction(_event) do
    {:error, "Update action is not yet supported"}
  end

  @spec retry(fun(), integer(), {Event.t(), map()}) :: {:error, any()} | {:ok, any()}
  def retry(fun, attempts, {event, map} = args) when attempts > 0 do
    try do
      apply(fun, [event, map])
    rescue
      Ecto.StaleEntryError ->
        delay = (@max_retries - attempts + 1) * @retry_interval
        EventStore.add_error(event, "OCC conflict detected, retrying after #{delay} ms... #{attempts - 1} attempts left")
        :timer.sleep(delay)
        retry(fun, attempts - 1, args)
    end
  end

  def retry(_fun, 0, _args) do
    {:error, "OCC conflict: Max number of #{@max_retries} retries reached"}
  end
end
