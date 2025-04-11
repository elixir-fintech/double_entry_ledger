defmodule DoubleEntryLedger.EventWorker.CreateEvent do
  @moduledoc """
  Provides helper functions for handling events with the `action: :create` attribute
  in the double-entry ledger system.
  """

  use DoubleEntryLedger.OccProcessor

  alias Ecto.{
    Changeset,
    Multi
  }

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    EventStore,
    EventStoreHelper,
    TransactionStore,
    Repo
  }

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
  @spec process_create_event(Event.t(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process_create_event(event, repo \\ Repo) do
    case process_with_retry(event, repo) do
      {:ok, %{transaction: transaction, event: update_event}} ->
        {:ok, transaction, update_event}

      {:error, :transaction, :occ_final_timeout, event} ->
        {:error, event}

      {:error, :transaction_map, error, event} ->
        handle_error(event, "Failed to transform transaction data: #{inspect(error)}")

      {:error, step, error, _} ->
        handle_error(event, "#{step} step failed: #{inspect(error)}")

      {:error, error} ->
        handle_error(event, "#{inspect(error)}")
    end
  end

  @impl true
  def build_transaction(event, transaction_map, repo) do
    Multi.new()
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: td} ->
      EventStoreHelper.build_mark_as_processed(event, td.id)
    end)
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
