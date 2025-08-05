defmodule DoubleEntryLedger.EventWorker.CreateTransactionEventMapNoSaveOnError do
  @moduledoc """
  Processes event maps for creating transactions, returning changesets on error instead of raising or saving invalid data.

  This module is used for event ingestion where errors (such as invalid entry data, duplicate source keys, or OCC timeouts) should not result in partial saves or exceptions, but instead return a changeset with error details. It leverages OCC (optimistic concurrency control) and changeset validation to ensure only valid, unique, and fully processed events are persisted.

  ## Error Handling
  - Returns a changeset with errors for invalid input, duplicate keys, OCC timeouts, or account mismatches.
  - Errors are attached to the `:input_event_map` or other relevant fields in the changeset.
  """

  use DoubleEntryLedger.Occ.Processor

  import DoubleEntryLedger.EventWorker.ResponseHandler,
    only: [default_event_map_response_handler: 3]

  alias DoubleEntryLedger.{EventWorker, Repo}

  alias DoubleEntryLedger.Event.EventMap

  alias Ecto.Changeset

  @impl true
  # this function will never be called, as we don't save on error
  # but we need to implement it to satisfy the behaviour
  defdelegate handle_occ_final_timeout(event_map, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_occ_final_timeout

  @impl true
  defdelegate build_transaction(event_map, transaction_map, repo),
    to: DoubleEntryLedger.EventWorker.CreateTransactionEventMap,
    as: :build_transaction

  @impl true
  defdelegate handle_build_transaction(multi, event_map, repo),
    to: DoubleEntryLedger.EventWorker.CreateTransactionEventMap,
    as: :handle_build_transaction

  @doc """
  Processes an event map for transaction creation, returning a changeset on error.

  This function attempts to process the event map using OCC and entry validation. If the event is invalid (e.g., invalid entry data, duplicate source key, OCC timeout, or account mismatch), it returns an Ecto.Changeset with error details attached to the `:input_event_map` or other relevant fields. No partial data is saved on error.

  ## Returns
  - `{:ok, transaction, event}` on success
  - `{:error, changeset}` if validation or OCC fails (see changeset errors for details)
  - `{:error, string}` for unexpected errors
  """
  @spec process(EventMap.t(), Ecto.Repo.t() | nil) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process(%{action: :create_transaction} = event_map, repo \\ Repo) do
    case process_with_retry_no_save_on_error(event_map, repo) do
      {:error, :occ_timeout, %Changeset{data: %EventMap{}} = changeset, _steps_so_far} ->
        Logger.warning(
          "#{@module_name}: OCC timeout reached",
          EventMap.log_trace(event_map, changeset.errors)
        )

        {:error, changeset}

      {:error, :input_event_map_error, %Changeset{data: %EventMap{}} = changeset, _steps_so_far} ->
        Logger.error(
          "#{@module_name}: Input event map error",
          EventMap.log_trace(event_map, changeset.errors)
        )

        {:error, changeset}

      response ->
        default_event_map_response_handler(response, event_map, @module_name)
    end
  end

  @impl true
  def handle_transaction_map_error(event_map, error, _repo) do
    event_map_changeset =
      event_map
      |> EventMap.changeset(%{})
      |> Changeset.add_error(:input_event_map, to_string(error))

    Multi.new()
    |> Multi.error(:input_event_map_error, event_map_changeset)
  end
end
