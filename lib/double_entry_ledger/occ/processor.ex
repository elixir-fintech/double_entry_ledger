defmodule DoubleEntryLedger.Occ.Processor do
  @moduledoc """
  Behavior definition for implementing Optimistic Concurrency Control (OCC) in event processing.

  This module provides a comprehensive framework for handling event processing with
  optimistic concurrency control, including automatic retries with exponential backoff,
  error tracking, and standardized transaction handling.

  ## Key Features

  * **Behavior Definition**: Defines a standard interface for OCC-aware event processors
  * **Default Implementations**: Provides sensible defaults for retry logic and error handling
  * **Exponential Backoff**: Implements intelligent retry timing to reduce contention
  * **Error Tracking**: Maintains detailed error history through the retry process
  * **Consistent API**: Enforces a consistent approach to transaction processing across the system

  ## Usage

  Modules that need OCC capabilities can simply use this behavior:

  ```elixir
  defmodule MyEventProcessor do
    use DoubleEntryLedger.Occ.Processor

    @impl true
    def build_transaction(event, transaction_map, repo) do
      # Your specific transaction building logic here
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:event, event_changeset)
      |> Ecto.Multi.insert(:transaction, transaction_changeset)
    end
  end
  ```

  The processor will automatically handle:
  * Converting event data to transaction maps
  * Retrying on StaleEntryError
  * Tracking retry attempts
  * Managing timeouts and backoff
  * Preserving error contexts

  Implementing modules only need to define how to build the transaction - all OCC handling is managed by this behavior. "
  """

  alias DoubleEntryLedger.Event.ErrorMap
  alias DoubleEntryLedger.{Event, Transaction}
  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.EventWorker.EventTransformer

  @doc """
  Builds an Ecto.Multi transaction for processing an event.

  This callback must be implemented by modules using the OccProcessor behavior.
  It defines how to construct the database transaction operations needed to process
  the event and its associated transaction data.

  ## Required Transaction Steps

  The Multi must include specific named steps depending on the input type:

  * `:create_event` (required for EventMap) - Must return the created Event struct when processing the EventMap
  * `:transaction` (required) - Must return the saved Transaction struct and it must handle the Ecto.StaleEntryError and return it as the error for the Multi.failure()
  * `:event`(required) - Must return the saved Event struct when processing the Event

  ## Parameters

  * `event_or_map`: An Event struct or EventMap containing the event details to process
  * `transaction_map`: A map of transaction data derived from the event
  * `repo`: The Ecto repository to use for database operations

  ## Returns

  * An `Ecto.Multi` struct containing all the operations to execute atomically

  ## Implementation Examples

  See implementations in:
  * `DoubleEntryLedger.EventWorker.CreateEvent.build_transaction/3`
  * `DoubleEntryLedger.EventWorker.UpdateEvent.build_transaction/3`
  * `DoubleEntryLedger.EventWorker.ProcessEventMap.build_transaction/3`
  """
  @callback build_transaction(
              Event.t() | EventMap.t(),
              EventTransformer.transaction_map(),
              Ecto.Repo.t()
            ) ::
              Ecto.Multi.t()

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
      @behaviour DoubleEntryLedger.Occ.Processor
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
      Process with retry for modules implementing Occ.Processor behavior.

      This function handles retrying a transaction when StaleEntryError occurs,
      with exponential backoff and error tracking.

      ## Parameters
        - `module`: The module implementing the Occ.Processor behavior
        - `event`: The event being processed
        - `transaction_map`: Transaction data
        - `attempts`: Number of remaining retry attempts
        - `repo`: Ecto repository
      """
      @spec retry(
              module(),
              Event.t() | EventMap.t(),
              EventTransformer.transaction_map(),
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

      # Clean up when attempts are exhausted
      def retry(module, event_or_map, _transaction_map, error_map, 0, repo) do
        event_or_map
        |> finally!(error_map, repo)
      end

      @spec finally!(Event.t() | EventMap.t(), ErrorMap.t(), Ecto.Repo.t()) ::
              {:error, :transaction, :occ_final_timeout, Event.t()}
      defp finally!(event, error_map, repo) when is_struct(event, Event) do
        event
        |> occ_timeout_changeset(error_map)
        |> repo.update!()
        |> then(&{:error, :transaction, :occ_final_timeout, &1})
      end

      defp finally!(event_map, error_map, repo) when is_struct(event_map, EventMap) do
        error_map.steps_so_far.create_event
        |> occ_timeout_changeset(error_map)
        |> repo.insert!()
        |> then(&{:error, :transaction, :occ_final_timeout, &1})
      end

      @spec occ_timeout_changeset(Event.t(), ErrorMap.t()) ::
              Ecto.Changeset.t()
      defp occ_timeout_changeset(
             event,
             %{errors: errors, retries: retries}
           ) do
        event
        |> Ecto.Changeset.change(
          errors: errors,
          status: :occ_timeout,
          occ_retry_count: retries
        )
      end

      @spec update_event!(Event.t() | EventMap.t(), ErrorMap.t(), Ecto.Repo.t()) ::
              Event.t() | EventMap.t()
      defp update_event!(event, %{errors: errors, retries: retries}, repo)
           when is_struct(event, Event) do
        event
        |> Ecto.Changeset.change(occ_retry_count: retries, errors: errors)
        |> repo.update!()
      end

      defp update_event!(event_map, _, _) when is_struct(event_map, EventMap), do: event_map

      defoverridable build_transaction: 3
    end
  end
end
