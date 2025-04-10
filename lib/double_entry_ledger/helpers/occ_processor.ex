defmodule DoubleEntryLedger.OccProcessor do
  @moduledoc """
  This module defines the behaviour for processing events with optimistic concurrency control (OCC).
  It provides a callback for building transactions and a default implementation for processing events
  with retry logic.
  """

  alias DoubleEntryLedger.OccProcessor
  alias Ecto.{Multi, Repo}
  alias DoubleEntryLedger.{Event, Transaction}
  import DoubleEntryLedger.EventWorker.ErrorHandler
  import DoubleEntryLedger.OccRetry

  @doc """
  Builds a transaction for the given event and data.

  Implementations should return an Ecto.Multi that includes the transaction logic.
  """
  @callback build_transaction(Event.t(), map(), Repo.t()) :: Multi.t()

  @doc """
  Process the event with retry mechanisms.

  This callback has a default implementation through the __using__ macro.
  """
  @callback process_with_retry(Event.t(), map(), integer(), Repo.t()) ::
    {:ok, %{transaction: Transaction.t(), event: Event.t()}} |
    {:error, any()} |
    Multi.failure()

  @callback stale_error_handler(Event.t() | map(), non_neg_integer(), map()) :: Even.t() | map()

  @callback finally(Event.t(), map()) :: {:error, String.t()} | {:error, atom(), atom(), Event.t()}


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
  def retry(module, event, transaction_map, error_map, attempts, repo)

  def retry(module, event, transaction_map, error_map, attempts, repo) when attempts > 0 do
    case module.build_transaction(event, transaction_map, repo)
         |> repo.transaction() do
      {:error, :transaction, %Ecto.StaleEntryError{}, steps_so_far} ->
        new_error_map = update_error_map(error_map, attempts, steps_so_far)
        updated_event = module.stale_error_handler(event, attempts, new_error_map)
        set_delay_timer(attempts)
        retry(module, updated_event, transaction_map, new_error_map, attempts - 1, repo)

      result ->
        result
    end
  end

  def retry(module, event, _transaction_map, error_map, 0, _repo) do
    module.finally(event, error_map)
  end

  def create_error_map do
    %{
      errors: [],
      steps_so_far: %{},
      retries: 0,
      attempts: max_retries()
    }
  end

  defp update_error_map(error_map, attempts, steps_so_far) do
    %{
      errors: build_errors(occ_error_message(attempts), error_map.errors),
      steps_so_far: steps_so_far,
      retries: error_map.retries + 1,
    }
  end

   # --- Use Macro for Default Implementations ---

  defmacro __using__(_opts) do
   quote do
      @behaviour DoubleEntryLedger.OccProcessor
      import DoubleEntryLedger.OccRetry

      @max_retries max_retries()
      @retry_interval retry_interval()

      @impl true
      def process_with_retry(event, transaction_map, attempts, repo \\ DoubleEntryLedger.Repo) do
        error_map = OccProcessor.create_error_map()
        OccProcessor.retry(__MODULE__, event, transaction_map, error_map, attempts, repo)
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

      defoverridable [process_with_retry: 4, stale_error_handler: 3, build_transaction: 3, finally: 2]
    end
  end
end
