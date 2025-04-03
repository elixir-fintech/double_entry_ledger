defmodule DoubleEntryLedger.EventWorker.EventMap do
  @moduledoc """
  Provides functions to process event maps by creating event records and handling associated transactions.
  """

  alias DoubleEntryLedger.{
    Event,
    EventStore,
    Transaction,
    TransactionStore,
    Repo,
    OccRetry,
    EventStoreHelper
  }
  alias DoubleEntryLedger.Event.EntryData
  alias DoubleEntryLedger.Event.TransactionData
  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.EventWorker.EventTransformer
  alias DoubleEntryLedger.EventStore.CreateEventError
  alias Ecto.{Multi, Changeset}
  import OccRetry
  import EventTransformer, only: [transaction_data_to_transaction_map: 2]

  @type event_error_map :: %{
          errors:
            list(%{
              message: String.t(),
              inserted_at: DateTime.t()
            }),
          steps_so_far: map(),
          retries: integer()
        }

  @doc """
  Processes an event map using the default repository.

  ## Parameters
    - `event_map`: A map representing the event data.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_map(EventMap.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t() | Changeset.t()}
  def process_map(event_map) do
    process_map(event_map, Repo)
  end

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
          {:ok, Transaction.t(), Event.t()} | {:error, String.t() | Changeset.t()}
  def process_map(%EventMap{transaction_data: transaction_data, instance_id: id} = event_map, repo) do

    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        event_error_map = %{errors: [], steps_so_far: %{}, retries: 1}

        case process_map_with_retry(
               EventMap.to_map(event_map),
               transaction_map,
               event_error_map,
               max_retries(),
               repo
             ) do

          {:ok, %{transaction: transaction, event: event}} ->
            {:ok, transaction, event}

          {:error, :transaction, :occ_final_timeout, _event} ->
            {:error, occ_final_error_message()}

          {:error, :get_create_event_transaction, %CreateEventError{reason: :create_event_pending} = error, steps_so_far} ->
            EventStore.create_event_after_failure(steps_so_far.create_event, [build_error(error.message)], 1, :pending)
            {:error, error.message}

          {:error, :get_create_event_transaction, %CreateEventError{} = error, steps_so_far} ->
            EventStore.create_event_after_failure(steps_so_far.create_event, [build_error(error.message)], 1, :failed)
            {:error, error.message}

          {:error, :create_event, %Changeset{data: %Event{}} = event_changeset, _steps_so_far} ->
            event_map_changeset =
              transfer_errors_from_event_to_event_map(event_map, event_changeset)
            {:error, event_map_changeset}

          {:error, :transaction, %Changeset{data: %Transaction{}} = trx_changeset, _steps_so_far} ->
            event_map_changeset =
              transfer_errors_from_trx_to_event_map(event_map, trx_changeset)
            {:error, event_map_changeset}

          {:error, step, error, _steps_so_far} ->
            {:error, "#{step} failed: #{inspect(error)}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec process_map_with_retry(map(), map(), event_error_map(), integer(), Ecto.Repo.t()) ::
          {:ok, %{transaction: Transaction.t(), event: Event.t()}}
          | {:error, String.t()}
          | Ecto.Multi.failure()
  def process_map_with_retry(event_map, transaction_map, error_map, attempts, repo)
      when attempts > 0 do
    case build_process_event_map(event_map, transaction_map, repo) |> repo.transaction() do
      {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
        new_error_map = %{
          errors: build_errors(occ_error_message(attempts), error_map.errors),
          steps_so_far: steps_so_far,
          retries: error_map.retries + 1
        }

        set_delay_timer(attempts)
        process_map_with_retry(event_map, transaction_map, new_error_map, attempts - 1, repo)

      result ->
        result
    end
  end

  def process_map_with_retry(_, _, error_map, 0, _) do
    case EventStore.create_event_after_failure(
           error_map.steps_so_far.create_event,
           [build_error(occ_final_error_message()) | error_map.errors],
           error_map.retries,
           :occ_timeout
         ) do
      {:ok, event} ->
        {:error, :transaction, :occ_final_timeout, event}

      {:error, changeset} ->
        {:error, "Failed to create event after OCC timeout: #{inspect(changeset)}"}
    end
  end

  @spec build_process_event_map(map(), map(), Ecto.Repo.t()) ::
          Ecto.Multi.t()
  defp build_process_event_map(%{action: :create} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStoreHelper.build_create(new_event_map))
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStoreHelper.build_mark_as_processed(event, transaction.id)
    end)
  end

  defp build_process_event_map(%{action: :update} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStoreHelper.build_create(new_event_map))
    |> EventStoreHelper.build_get_create_event_transaction(:get_create_event_transaction, :create_event)
    |> TransactionStore.build_update(:transaction, :get_create_event_transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStoreHelper.build_mark_as_processed(event, transaction.id)
    end)
  end

  @spec build_errors(String.t(), list()) :: list()
  defp build_errors(error_message, errors) do
    [build_error(error_message) | errors]
  end

  @spec build_error(String.t()) :: %{message: String.t(), inserted_at: DateTime.t()}
  defp build_error(error) do
    %{
      message: error,
      inserted_at: DateTime.utc_now(:microsecond)
    }
  end

  defp transfer_errors_from_trx_to_event_map(event_map, trx_changeset) do
    errors = get_all_errors(trx_changeset)
    entry_errors = Map.get(errors, :entries, [])
    transaction_data = event_map.transaction_data
    entries = transaction_data.entries

    entry_changesets = entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      EntryData.changeset(%EntryData{}, EntryData.to_map(entry))
      |> add_entry_data_errors(Enum.at(entry_errors, index))
      |> Map.put(:action, :insert)
    end)

    transaction_data_changeset =
      TransactionData.changeset(%TransactionData{}, TransactionData.to_map(transaction_data))
      |> Changeset.put_embed(:entries, entry_changesets)
      |> Map.put(:action, :insert)

    EventMap.changeset(%EventMap{}, EventMap.to_map(event_map))
    |> Changeset.put_embed(:transaction_data, transaction_data_changeset)
    |> Map.put(:action, :insert)
  end

  defp add_entry_data_errors(changeset, entry_errors) do
    [:currency, :amount, :account_id]
    |> Enum.reduce(changeset, &add_errors_to_changeset(&2, &1, entry_errors))
  end

  @spec transfer_errors_from_event_to_event_map(EventMap.t(), Changeset.t()) :: Changeset.t()
  defp transfer_errors_from_event_to_event_map(event_map, event_changeset) do
    errors = get_all_errors(event_changeset)
    EventMap.changeset(%EventMap{}, EventMap.to_map(event_map))
    |> add_event_errors(errors)
    |> Map.put(:action, :insert)
  end

  @spec add_event_errors(Changeset.t(), map()) :: Changeset.t()
  defp add_event_errors(event_map_changeset, errors) do
    [:update_idempk, :source_idempk]
    |> Enum.reduce(event_map_changeset, &add_errors_to_changeset(&2, &1, errors))
  end

  @spec get_all_errors(Changeset.t()) :: map()
  defp get_all_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @spec add_errors_to_changeset(Changeset.t(), atom(), map()) :: Changeset.t()
  defp add_errors_to_changeset(changeset, field, errors) do
    if Map.has_key?(errors, field) do
      Map.get(errors, field)
      |> Enum.reduce(changeset, &Changeset.add_error(&2, field, &1))
    else
      changeset
    end
  end
end
