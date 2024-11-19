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
    UpdateEvent,
    OccRetry
  }

  alias DoubleEntryLedger.EventWorker.{
    EventTransformer,
    UpdateEvent
  }

  alias Ecto.Multi
  import UpdateEvent, only: [process_update_event: 1]
  import OccRetry
  import EventTransformer, only: [transaction_data_to_transaction_map: 2]

  @type event_error_map :: %{
          errors:
            list(%{
              message: String.t(),
              inserted_at: DateTime.t()
            }),
          steps_so_far: map()
        }

  @doc """
  Processes an event map using the default repository.

  ## Parameters
    - `event_map`: A map representing the event data.

  ## Returns
    - `{:ok, transaction, event}` on success.
    - `{:error, reason}` on failure.
  """
  @spec process_map(Event.event_map()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
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
  @spec process_map(Event.event_map(), Ecto.Repo.t()) ::
          {:ok, Transaction.t(), Event.t()} | {:error, String.t()}
  def process_map(%{transaction_data: transaction_data, instance_id: id} = event_map, repo) do
    case transaction_data_to_transaction_map(transaction_data, id) do
      {:ok, transaction_map} ->
        event_error_map = %{errors: [], steps_so_far: %{}}

        case process_map_with_retry(
               event_map,
               transaction_map,
               event_error_map,
               max_retries(),
               repo
             ) do
          {:ok, %{process_event: %{transaction: transaction}, update_event: event}} ->
            {:ok, transaction, event}

          {:ok, %{transaction: transaction, event: event}} ->
            {:ok, transaction, event}

          {:error, :transaction, :occ_final_timeout, _event} ->
            {:error, occ_final_error_message()}

          {:error, step, error, _steps_so_far} ->
            {:error, "#{step} failed: #{error}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec process_map_with_retry(
          Event.event_map(),
          map(),
          event_error_map(),
          integer(),
          Ecto.Repo.t()
        ) ::
          {:ok, %{create_event: Event.t(), transaction: Transaction.t(), event: Event.t()}}
          | {:ok,
             %{
               create_event: Event.t(),
               process_event: %{transaction: Transaction.t(), event: Event.t()},
               update_event: Event.t()
             }}
          | {:ok, %{transaction: Transaction.t(), event: Event.t()}}
          | {:error, String.t()}
          | Ecto.Multi.failure()
  def process_map_with_retry(event_map, transaction_map, error_map, attempts, repo)
      when attempts > 0 do
    case build_process_event_map(event_map, transaction_map, repo) |> repo.transaction() do
      {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
        new_error_map = %{
          errors: build_errors(occ_error_message(attempts), error_map.errors),
          steps_so_far: steps_so_far
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
           :occ_timeout
         ) do
      {:ok, event} ->
        {:error, :transaction, :occ_final_timeout, event}

      {:error, changeset} ->
        {:error, "Failed to create event after OCC timeout: #{inspect(changeset)}"}
    end
  end

  @spec build_process_event_map(Event.event_map(), map(), Ecto.Repo.t()) ::
          Ecto.Multi.t()
  defp build_process_event_map(%{action: :create} = event_map, transaction_map, repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStore.build_insert_event(new_event_map))
    |> TransactionStore.build_create(:transaction, transaction_map, repo)
    |> Multi.update(:event, fn %{transaction: transaction, create_event: event} ->
      EventStore.build_mark_as_processed(event, transaction.id)
    end)
  end

  defp build_process_event_map(%{action: :update} = event_map, _transaction_map, _repo) do
    new_event_map = Map.put_new(event_map, :status, :pending)

    Multi.new()
    |> Multi.insert(:create_event, EventStore.build_insert_event(new_event_map))
    |> Multi.run(:process_event, fn _repo, %{create_event: new_event} ->
      case process_update_event(new_event) do
        {:ok, {transaction, event}} -> {:ok, %{transaction: transaction, event: event}}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.update(:update_event, fn %{process_event: %{transaction: transaction, event: event}} ->
      EventStore.build_mark_as_processed(event, transaction.id)
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
end
