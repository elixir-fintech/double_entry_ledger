defmodule DoubleEntryLedger.OccProcessor do
  @moduledoc """
  This module defines the behaviour for processing events with optimistic concurrency control (OCC).
  It provides a callback for building transactions and a default implementation for processing events
  with retry logic.
  """

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
              | {:error, any()}
              | Ecto.Multi.failure()

  @callback stale_error_handler(Event.t() | map(), non_neg_integer(), map()) :: Event.t() | map()

  @callback finally(Event.t(), map()) ::
              {:error, String.t()} | {:error, atom(), atom(), Event.t()}

  # --- Use Macro for Default Implementations ---

  defmacro __using__(_opts) do
    quote do
      @behaviour DoubleEntryLedger.OccProcessor
      alias DoubleEntryLedger.Repo
      import DoubleEntryLedger.OccRetry

      import DoubleEntryLedger.EventWorker.EventTransformer,
        only: [transaction_data_to_transaction_map: 2]

      @max_retries max_retries()
      @retry_interval retry_interval()

      @impl true
      def process_with_retry(%{instance_id: id, transaction_data: td} = event_or_map, repo \\ Repo) do
        error_map = create_error_map(event_or_map)

        case transaction_data_to_transaction_map(td, id) do
          {:ok, transaction_map} ->
            retry(__MODULE__, event_or_map, transaction_map, error_map, max_retries(), repo)

          {:error, error} ->
            {:error, :transaction_map, error, event_or_map}
        end
      end

      @impl true
      def stale_error_handler(event_or_map, _attempts, _error_map) do
        # Default implementation: just return the event or map
        event_or_map
      end

      @impl true
      def build_transaction(_event, _transaction_map, _repo) do
        raise "build_transaction/3 not implemented"
      end

      @impl true
      def finally(_event, _error_map) do
        raise "final retry/1 not implemented"
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
      def retry(module, event_or_map, transaction_map, error_map, attempts, repo)

      def retry(module, event_or_map, transaction_map, error_map, attempts, repo) when attempts > 0 do
        case module.build_transaction(event_or_map, transaction_map, repo)
             |> repo.transaction() do
          {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
            new_error_map = update_error_map(error_map, attempts, steps_so_far)

            updated_event_or_map =
              event_or_map
              |> update_occ_tries(new_error_map, repo)
              |> module.stale_error_handler(attempts, new_error_map)

            set_delay_timer(attempts)

            retry(module, updated_event_or_map, transaction_map, new_error_map, attempts - 1, repo)

          result ->
            result
        end
      end

      def retry(module, event, _transaction_map, error_map, 0, _repo) do
        module.finally(event, error_map)
      end

      defp update_occ_tries(event_or_map, error_map, repo) do
        if is_struct(event_or_map, Event) do
          event_or_map
          |> Ecto.Changeset.change(occ_retry_count: error_map.retries)
          |> repo.update!()
        else
          event_or_map
        end
      end

      defp update_error_map(error_map, attempts, steps_so_far) do
        %{
          errors: build_occ_errors(occ_error_message(attempts), error_map.errors),
          steps_so_far: steps_so_far,
          retries: error_map.retries + 1
        }
      end

      defp create_error_map(event) do
        %{
          errors: Map.get(event, :errors, []),
          steps_so_far: %{},
          retries: 0
        }
      end

      defoverridable stale_error_handler: 3, build_transaction: 3, finally: 2
    end
  end
end
