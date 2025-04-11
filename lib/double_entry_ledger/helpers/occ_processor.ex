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
            new_error_map = update_error_map(error_map, occ_error_message(attempts), steps_so_far)

            updated_event_or_map =
              event_or_map
              |> update_event!(new_error_map, repo)

            set_delay_timer(attempts)

            retry(module, updated_event_or_map, transaction_map, new_error_map, attempts - 1, repo)

          result ->
            result
        end
      end

      def retry(module, event_or_map, _transaction_map, error_map, 0, repo) do
        # Final retry attempt
        new_error_map =
          update_error_map(error_map, occ_final_error_message(), error_map.steps_so_far, false)
        event_or_map
        |> update_event!(new_error_map, repo)
        |> module.finally(new_error_map)
      end

      defp update_event!(event_or_map, %{errors: errors, retries: retries}, repo) do
        if is_struct(event_or_map, Event) do
          event_or_map
          |> Ecto.Changeset.change(
              occ_retry_count: retries,
              errors: errors
            )
          |> repo.update!()
        else
          event_or_map
        end
      end

      defp update_error_map(error_map, message, steps_so_far, update_tries \\ true) do
        %{
          errors: build_occ_errors(message, error_map.errors),
          steps_so_far: steps_so_far,
          retries: (update_tries && error_map.retries + 1) || error_map.retries
        }
      end

      defp create_error_map(event) do
        %{
          errors: Map.get(event, :errors, []),
          steps_so_far: %{},
          retries: 0
        }
      end

      defoverridable build_transaction: 3, finally: 2
    end
  end
end
