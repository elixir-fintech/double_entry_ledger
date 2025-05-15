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
  alias Ecto.Multi
  alias DoubleEntryLedger.{Event, Transaction}
  alias DoubleEntryLedger.Event.ErrorMap
  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.EventWorker.EventTransformer
  alias DoubleEntryLedger.Occ.Occable

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

  * `occable_item`: An Event struct or EventMap containing the event details to process
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
              {:ok, %{transaction: Transaction.t(), event_success: Event.t()}}
              | {:ok, %{event_failure: Event.t()}}
              | Ecto.Multi.failure()

  # --- Use Macro for Default Implementations ---

  defmacro __using__(_opts) do
    quote do
      @behaviour DoubleEntryLedger.Occ.Processor
      alias DoubleEntryLedger.Repo
      alias Ecto.Multi
      import DoubleEntryLedger.Occ.Helper
      import DoubleEntryLedger.EventQueue.Scheduling

      import DoubleEntryLedger.EventWorker.EventTransformer,
        only: [transaction_data_to_transaction_map: 2]

      @max_retries max_retries()
      @retry_interval retry_interval()

      @impl true
      def process_with_retry(
            %{instance_id: id, transaction_data: td} = occable_item,
            repo \\ Repo
          ) do
        %ErrorMap{} = error_map = create_error_map(occable_item)

        retry(__MODULE__, occable_item, error_map, max_retries(), repo)
      end

      @impl true
      def build_transaction(_event, _transaction_map, _repo) do
        raise "build_transaction/3 not implemented"
      end

      def build_multi(occable_item, repo) do
        Multi.new()
        |> Multi.put(:occable_item, occable_item)
        |> Multi.run(:transaction_map, fn _, %{occable_item: %{instance_id: id, transaction_data: td}} ->
          case transaction_data_to_transaction_map(td, id) do
            {:ok, transaction_map} -> {:ok, transaction_map}
            {:error, error} -> {:ok, {:error, error}}
          end
        end)
        |> Multi.merge(fn
          %{transaction_map: {:error, error}, occable_item: item} ->
            Multi.update(Multi.new(), :event_failure, fn _ ->
              build_schedule_retry_with_reason(item, error, :failed)
            end)

          %{transaction_map: transaction_map, occable_item: item} ->
            build_transaction(item, transaction_map, repo)
            |> Multi.update(:event_success, fn %{transaction: td} ->
              build_mark_as_processed(item, td.id)
            end)
        end)
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
              Occable.t(),
              ErrorMap.t(),
              non_neg_integer(),
              Ecto.Repo.t()
            ) ::
              {:ok, %{transaction: Transaction.t(), event_success: Event.t()}}
              | {:ok, %{event_failure: Event.t()}}
              | Ecto.Multi.failure()
      def retry(module, occable_item, error_map, attempts, repo)
          when attempts > 0 do

        multi = build_multi(occable_item, repo)

        case repo.transaction(multi) do
          {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
            new_error_map = update_error_map(error_map, attempts, steps_so_far)
#           updated_occable_item = Occable.update!(occable_item, new_error_map, repo)

            if attempts > 1 do
              # no need to set timer for base retry
              set_delay_timer(attempts)
            end

            retry(
              module,
              occable_item,
              new_error_map,
              attempts - 1,
              repo
            )

          result ->
            result
        end
      end

      # Clean up when attempts are exhausted
      def retry(module, occable_item, error_map, 0, repo) do
        Occable.timed_out(occable_item, :occable_item, error_map)
        |> Multi.update(:event_failure, fn %{occable_item: occable_item} ->
          build_schedule_retry_with_reason(
            occable_item,
            nil,
            :occ_timeout
          )
        end)
        |> repo.transaction()
      end

      defoverridable build_transaction: 3
    end
  end
end
