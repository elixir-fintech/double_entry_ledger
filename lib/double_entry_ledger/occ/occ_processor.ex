defmodule DoubleEntryLedger.OccProcessor do
  @moduledoc """
  This module defines the behaviour for processing events with optimistic concurrency control (OCC).
  It provides a callback for building transactions and a default implementation for processing events
  with retry logic.
  """

  alias DoubleEntryLedger.Event.ErrorMap
  alias DoubleEntryLedger.{Event, Transaction}
  alias DoubleEntryLedger.Event.EventMap

  @doc """
  Builds a transaction for the given event and data.

  Implementations should return an Ecto.Multi that includes the transaction logic.
  """
  @callback build_transaction(Event.t(), map(), Ecto.Repo.t()) :: Ecto.Multi.t()

  @doc """
  Process the event with retry mechanisms.

  This callback has a default implementation through the __using__ macro.
  """
  @callback process_with_retry(Event.t() | EventMap.t(), Ecto.Repo.t()) ::
              {:ok, %{transaction: Transaction.t(), event: Event.t()}}
              | Ecto.Multi.failure()
              | {:error, :transaction, :occ_final_timeout, Event.t()}
              | {:error, :transaction_map, String.t(), Event.t() | EventMap.t()}

  # --- Use Macro for Default Implementations ---

  defmacro __using__(_opts) do
    quote do
      @behaviour DoubleEntryLedger.OccProcessor
      alias DoubleEntryLedger.Repo
      import DoubleEntryLedger.Occ.Helper

      import DoubleEntryLedger.EventWorker.EventTransformer,
        only: [transaction_data_to_transaction_map: 2]

      @max_retries max_retries()
      @retry_interval retry_interval()

      @impl true
      def process_with_retry(
            %{instance_id: id, transaction_data: td} = event_or_map,
            repo \\ Repo
          ) do

        %ErrorMap{} = error_map = create_error_map(event_or_map)

        case transaction_data_to_transaction_map(td, id) do
          {:ok, transaction_map} ->
            retry(__MODULE__, event_or_map, transaction_map, error_map, max_retries(), repo)

          {:error, error} ->
            {:error, :transaction_map, error, event_or_map}
        end
      end

      @impl true
      def build_transaction(_event, _transaction_map, _repo) do
        raise "build_transaction/3 not implemented"
      end

      # --- Retry Logic ---

      @doc """
      Process with retry for modules implementing OccProcessor behavior.

      This function handles retrying a transaction when StaleEntryError occurs,
      with exponential backoff and error tracking.

      ## Parameters
        - `module`: The module implementing the OccProcessor behavior
        - `event`: The event being processed
        - `transaction_map`: Transaction data
        - `attempts`: Number of remaining retry attempts
        - `repo`: Ecto repository
      """
      @spec retry(
              module(),
              Event.t() | EventMap.t(),
              map(),
              ErrorMap.t(),
              non_neg_integer(),
              Ecto.Repo.t()
            ) ::
              {:ok, %{transaction: Transaction.t(), event: Event.t()}}
              | Ecto.Multi.failure()
              | {:error, :transaction, :occ_final_timeout, Event.t()}
              | {:error, :transaction_map, String.t(), Event.t() | EventMap.t()}
      def retry(module, event_or_map, transaction_map, error_map, attempts, repo)
          when attempts > 0 do
        case module.build_transaction(event_or_map, transaction_map, repo)
             |> repo.transaction() do
          {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
            new_error_map = update_error_map(error_map, attempts, steps_so_far)
            updated_event_or_map = update_event!(event_or_map, new_error_map, repo)

            if attempts > 1 do
              # no need to set timer for base retry
              set_delay_timer(attempts)
            end

            retry(
              module,
              updated_event_or_map,
              transaction_map,
              new_error_map,
              attempts - 1,
              repo
            )

          result ->
            result
        end
      end

      def retry(module, event_or_map, _transaction_map, error_map, 0, repo) do #Clean up when attempts are exhausted
        event_or_map
        |> finally!(error_map, repo)
      end

      @spec finally!(Event.t() | EventMap.t(), ErrorMap.t(), Ecto.Repo.t()) ::
              {:error, :transaction, :occ_final_timeout, Event.t()}
      defp finally!(event, error_map, repo) when is_struct(event, Event) do
        event
        |> occ_timeout_changeset(error_map)
        |> repo.update!()
        |> then(& {:error, :transaction, :occ_final_timeout, &1})
      end

      defp finally!(event_map, error_map, repo) when is_struct(event_map, EventMap) do
        error_map.steps_so_far.create_event
        |> occ_timeout_changeset(error_map)
        |> repo.insert!()
        |> then(& {:error, :transaction, :occ_final_timeout, &1})
      end

      @spec occ_timeout_changeset(Event.t(), ErrorMap.t()) ::
              Ecto.Changeset.t()
      defp occ_timeout_changeset(
             event,
             %{errors: errors, retries: retries}
           ) do
        {now, next_retry_after} = get_now_and_next_retry_after()

        event
        |> Ecto.Changeset.change(
          errors: errors,
          status: :occ_timeout,
          occ_retry_count: retries,
          processing_completed_at: now,
          next_retry_after: next_retry_after
        )
      end

      @spec update_event!(Event.t() | EventMap.t(), ErrorMap.t(), Ecto.Repo.t()) ::
              Event.t() | EventMap.t()
      defp update_event!(event, %{errors: errors, retries: retries}, repo) when is_struct(event, Event) do
          event
          |> Ecto.Changeset.change(occ_retry_count: retries, errors: errors)
          |> repo.update!()
      end

      defp update_event!(event_map, _, _) when is_struct(event_map, EventMap), do: event_map

      defoverridable build_transaction: 3
    end
  end
end
