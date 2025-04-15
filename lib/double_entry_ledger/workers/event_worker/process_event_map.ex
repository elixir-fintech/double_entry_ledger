defmodule DoubleEntryLedger.EventWorker.ProcessEventMap do
  @moduledoc """
  Provides functions to process event maps by creating event records and handling associated transactions.
  """
  use DoubleEntryLedger.OccProcessor

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    TransactionStore,
    Repo,
    EventStoreHelper
  }
  alias DoubleEntryLedger.Occ

  alias DoubleEntryLedger.Event.EventMap

  alias DoubleEntryLedger.EventWorker.AddUpdateEventError

  alias Ecto.{Multi, Changeset}
  import Occ.Helper
  import DoubleEntryLedger.EventWorker.ErrorHandler

  @doc """
  Processes an event map by creating an event record and handling the associated transaction using the specified repository.

  ## Parameters
    - `event_map`: A map representing the event data.
    - `repo`: The repository to use for database operations.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_map(EventMap.t(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process_map(event_map, repo \\ Repo) do
    case process_with_retry(event_map, repo) do
      {:ok, %{transaction: transaction, event: event}} ->
        {:ok, transaction, event}

      {:error, :transaction_map, error, _event} ->
        {:error, "#{inspect(error)}"}

      {:error, :transaction, :occ_final_timeout, event} ->
        {:error, event}

      {:error, :get_create_event_transaction, %AddUpdateEventError{} = error, steps_so_far} ->
        {:error, handle_add_update_event_error(error, steps_so_far, event_map)}

      {:error, :create_event, %Changeset{data: %Event{}} = event_changeset, _steps_so_far} ->
        {:error, transfer_errors_from_event_to_event_map(event_map, event_changeset)}

      {:error, :transaction, %Changeset{data: %Transaction{}} = trx_changeset, _steps_so_far} ->
        {:error, transfer_errors_from_trx_to_event_map(event_map, trx_changeset)}

      {:error, step, error, _steps_so_far} ->
        {:error, "#{step} failed: #{inspect(error)}"}
    end
  end

  @impl true
  def build_transaction(%{action: :create} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStoreHelper.build_create(new_event_map))
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStoreHelper.build_mark_as_processed(event, transaction.id)
    end)
  end

  def build_transaction(%{action: :update} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStoreHelper.build_create(new_event_map))
    |> EventStoreHelper.build_get_create_event_transaction(
      :get_create_event_transaction,
      :create_event
    )
    |> TransactionStore.build_update(
      :transaction,
      :get_create_event_transaction,
      transaction_map,
      repo
    )
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStoreHelper.build_mark_as_processed(event, transaction.id)
    end)
  end
end
