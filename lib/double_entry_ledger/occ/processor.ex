defmodule DoubleEntryLedger.Occ.Processor do
  @moduledoc """
  Behavior and default implementation for Optimistic Concurrency Control (OCC)
  in event processing.

  This module provides:

    * A behaviour defining four callbacks:
      - `build_transaction/3`
      - `handle_build_transaction/3`
      - `handle_transaction_map_error/3`
      - `handle_occ_final_timeout/2`
    * A `process_with_retry/2` implementation that:
      - Converts event data to a transaction map
      - Builds an Ecto.Multi via `build_multi/3`
      - Retries on `Ecto.StaleEntryError` with exponential backoff
      - Calls `handle_occ_final_timeout/2` when retries are exhausted
    * Helper imports for backoff, error tracking, and scheduling.

  ## Usage

      defmodule MyEventProcessor do
        use DoubleEntryLedger.Occ.Processor

        @impl true
        def build_transaction(event, tx_map, repo) do
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:transaction, Transaction.changeset(%Transaction{}, tx_map))
        end

        @impl true
        def handle_build_transaction(multi, event, _repo), do: multi

        @impl true
        def handle_transaction_map_error(event, error, _repo) do
          Ecto.Multi.new()
          |> Ecto.Multi.update(
            :event_failure,
            Command.changeset(event, %{status: :failed, errors: [inspect(error)]})
          )
        end

        @impl true
        def handle_occ_final_timeout(event, _repo) do
          Ecto.Multi.new()
          |> Ecto.Multi.update(
            :event_dead_letter,
            Command.changeset(event, %{status: :dead_letter})
          )
        end
      end

  """

  alias Ecto.Multi
  alias DoubleEntryLedger.{Command, Transaction}
  alias DoubleEntryLedger.Command.ErrorMap
  alias DoubleEntryLedger.Workers.CommandWorker.TransactionEventTransformer
  alias DoubleEntryLedger.Occ.Occable

  @doc """
  Builds an Ecto.Multi transaction for processing an event.

  This callback must be implemented by modules using the OccProcessor behavior.
  It defines how to construct the database transaction operations needed to process
  the event and its associated transaction data.

  ## Required Transaction Steps

  The Multi must include specific named steps depending on the input type:

    * `:create_event` (required for TransactionEventMap) - Must return the created Command struct when processing the TransactionEventMap
    * `:transaction` (required) - Must return the saved Transaction struct and it must handle the Ecto.StaleEntryError and return it as the error for the Multi.failure()
    * `:event` (required) - Must return the saved Command struct when processing the Command

  ## Parameters

    - `occable_item`: An Command struct or TransactionEventMap containing the event details to process
    - `transaction_map`: A map of transaction data derived from the event
    - `repo`: The Ecto repository to use for database operations

  ## Returns

    - An `Ecto.Multi` struct containing all the operations to execute atomically

  ## Implementation Examples

  See implementations in:
    * `DoubleEntryLedger.Workers.CommandWorker.CreateTransactionEvent.build_transaction/3`
    * `DoubleEntryLedger.Workers.CommandWorker.UpdateEvent.build_transaction/3`
    * `DoubleEntryLedger.Workers.CommandWorker.ProcessTransactionEventMap.build_transaction/3`
  """
  @callback build_transaction(
              Occable.t(),
              TransactionEventTransformer.transaction_map(),
              Ecto.UUID.t(),
              Ecto.Repo.t()
            ) :: Ecto.Multi.t()

  @doc """
  Allows further customization of the Ecto.Multi after the base transaction steps.

  This callback can be used to add additional steps or modify the Multi before execution.

  ## Parameters

    - `multi`: The Ecto.Multi built by `build_transaction/3`
    - `occable_item`: The event or event map being processed
    - `repo`: The Ecto repository

  ## Returns

    - An updated `Ecto.Multi`
  """
  @callback handle_build_transaction(Ecto.Multi.t(), Occable.t(), Ecto.Repo.t()) :: Ecto.Multi.t()

  @doc """
  Handles errors that occur when converting event data to a transaction map.

  This callback should return an Ecto.Multi that updates the event to reflect the error.

  ## Parameters

    - `occable_item`: The event or event map being processed
    - `error`: The error encountered during transaction map conversion
    - `repo`: The Ecto repository

  ## Returns

    - An `Ecto.Multi` that updates the event with error information
  """
  @callback handle_transaction_map_error(
              Occable.t(),
              any(),
              Ecto.Repo.t()
            ) :: Ecto.Multi.t()

  @doc """
  Handles the case when OCC retries are exhausted.

  This callback should return an Ecto.Multi that marks the event as permanently failed.

  ## Parameters

    - `occable_item`: The event or event map being processed
    - `repo`: The Ecto repository

  ## Returns

    - An `Ecto.Multi` that updates the event as dead letter or timed out
  """
  @callback handle_occ_final_timeout(
              Occable.t(),
              Ecto.Repo.t()
            ) :: Ecto.Multi.t()

  @doc """
  Process the event with retry mechanisms.

  This callback has a default implementation through the __using__ macro.
  """
  @callback process_with_retry(Occable.t(), Ecto.Repo.t()) ::
              {:ok, %{transaction: Transaction.t(), event_success: Command.t()}}
              | {:ok, %{event_failure: Command.t()}}
              | Ecto.Multi.failure()

  @callback process_with_retry_no_save_on_error(Occable.t(), Ecto.Repo.t()) ::
              {:ok, %{transaction: Transaction.t(), event_success: Command.t()}}
              | Ecto.Multi.failure()

  # --- Use Macro for Default Implementations ---

  defmacro __using__(_opts) do
    # Credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      @behaviour DoubleEntryLedger.Occ.Processor

      alias DoubleEntryLedger.Repo
      alias Ecto.Multi
      import DoubleEntryLedger.Occ.Helper
      import DoubleEntryLedger.CommandQueue.Scheduling

      import DoubleEntryLedger.Workers.CommandWorker.TransactionEventTransformer,
        only: [transaction_data_to_transaction_map: 2]

      @max_retries max_retries()
      @retry_interval retry_interval()

      @impl true
      @doc """
      Processes an event with OCC retry logic.

      Converts event data to a transaction map, builds an Ecto.Multi, and
      retries on `Ecto.StaleEntryError` up to the configured maximum.

      ## Parameters

        - `occable_item`: The event or event map to process
        - `repo`: The Ecto repository (defaults to `Repo`)

      ## Returns

        - `{:ok, %{transaction: Transaction.t(), event_success: Command.t()}}` on success
        - `{:ok, %{event_failure: Command.t()}}` on failure
        - `Ecto.Multi.failure()` on unrecoverable error
      """
      def process_with_retry(
            occable_item,
            repo \\ Repo
          ) do
        %ErrorMap{} = error_map = create_error_map(occable_item)
        retry(__MODULE__, occable_item, error_map, @max_retries, repo)
      end

      @impl true
      def process_with_retry_no_save_on_error(
            occable_item,
            repo \\ Repo
          ) do
        %ErrorMap{} = error_map = %{create_error_map(occable_item) | save_on_error: false}
        retry(__MODULE__, occable_item, error_map, @max_retries, repo)
      end

      @impl true
      def build_transaction(_event, _transaction_map, _instance_id, _repo) do
        raise "build_transaction/3 not implemented"
      end

      @impl true
      def handle_build_transaction(_multi, _event_or_map, _repo) do
        raise "handle_build_transaction/3 not implemented"
      end

      @impl true
      def handle_transaction_map_error(_occable_item, _error, _repo) do
        raise "handle_transaction_map_error/3 not implemented"
      end

      @impl true
      def handle_occ_final_timeout(_occable_item, _repo) do
        raise "handle_occ_final_timeout/2 not implemented"
      end

      @doc """
      Builds the shared `Ecto.Multi` pipeline for both success and error flows.

      1. `:transaction_map` – converts raw data to a map or returns an error tuple
      2. merges in either:
         - `handle_transaction_map_error/3` when conversion fails
         - `build_transaction/4` + `handle_build_transaction/3` on success

      ## Parameters

        - `module` - the processor module implementing the callbacks
        - `occable_item` - the Command or TransactionEventMap being processed
        - `repo` - the Ecto repo to use for DB ops

      ## Returns

        - an `Ecto.Multi` ready for `repo.transaction/1`
      """
      @spec build_multi(module(), Occable.t(), Ecto.Repo.t()) :: Multi.t()
      def build_multi(module, occable_item, repo) do
        Occable.build_multi(occable_item)
        |> Multi.merge(fn
          %{transaction_map: {:error, error}, occable_item: item} ->
            module.handle_transaction_map_error(item, error, repo)

          %{transaction_map: transaction_map, occable_item: item, instance: instance_id} ->
            module.build_transaction(item, transaction_map, instance_id, repo)
            |> module.handle_build_transaction(item, repo)
        end)
      end

      @doc """
      Retries the OCC pipeline on `Ecto.StaleEntryError` up to `@max_retries` times.

      On each failure, updates the `ErrorMap`, applies exponential backoff (with
      `set_delay_timer/1`), and tries again. Returns the first non‐error result.

      ## Parameters

        - `module` - the processor module
        - `occable_item` - the item being processed
        - `error_map` - the current retry/error state
        - `attempts` - remaining attempts
        - `repo` - the Ecto repo

      ## Returns

        - `{:ok, %{transaction: Transaction.t(), event_success: Command.t()}}`
        - `{:ok, %{event_failure: Command.t()}}`
        - `Ecto.Multi.failure()`
      """
      @spec retry(module(), Occable.t(), ErrorMap.t(), non_neg_integer(), Ecto.Repo.t()) ::
              {:ok, %{transaction: Transaction.t(), event_success: Command.t()}}
              | {:ok, %{event_failure: Command.t()}}
              | Ecto.Multi.failure()
      def retry(module, occable_item, error_map, attempts, repo)
          when attempts > 0 do
        multi = build_multi(module, occable_item, repo)

        case repo.transaction(multi) do
          {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
            new_error_map = update_error_map(error_map, attempts, steps_so_far)

            if attempts > 1, do: set_delay_timer(attempts)

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

      @doc """
      Finalizes when retry attempts are exhausted.

      Invokes `Occable.timed_out/3` to mark the item as timed out, merges in
      `handle_occ_final_timeout/2`, then runs one last transaction.

      ## Parameters

        - `module` - the processor module
        - `occable_item` - the item that timed out
        - `error_map` - the accumulated errors and retry count
        - `repo` - the Ecto repo

      ## Returns

        - The result of the final `repo.transaction/1`
      """
      def retry(module, occable_item, error_map, 0, repo) do
        name = :_occable_item

        Occable.timed_out(occable_item, name, error_map)
        |> Multi.merge(fn
          %{^name => occable_item} ->
            module.handle_occ_final_timeout(occable_item, repo)
        end)
        |> repo.transaction()
      end

      defoverridable build_transaction: 4,
                     handle_build_transaction: 3,
                     handle_transaction_map_error: 3,
                     handle_occ_final_timeout: 2
    end
  end
end
