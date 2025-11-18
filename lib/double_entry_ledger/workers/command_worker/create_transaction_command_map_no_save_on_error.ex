defmodule DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMapNoSaveOnError do
  @moduledoc """
  Processes event maps for creating transactions, returning changesets on error instead of raising or saving invalid data.

  This module is used for event ingestion where errors (such as invalid entry data, duplicate source keys, or OCC timeouts) should not result in partial saves or exceptions, but instead return a changeset with error details. It leverages OCC (optimistic concurrency control) and changeset validation to ensure only valid, unique, and fully processed events are persisted.

  ## Error Handling
  - Returns a changeset with errors for invalid input, duplicate keys, OCC timeouts, or account mismatches.
  - Errors are attached to the `:input_command_map` or other relevant fields in the changeset.
  """

  use DoubleEntryLedger.Occ.Processor
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.Changeset
  alias DoubleEntryLedger.Repo
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Workers.CommandWorker

  @impl true
  defdelegate handle_transaction_map_error(command_map, error, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
    as: :handle_transaction_map_error

  @impl true
  defdelegate build_transaction(command_map, transaction_map, instance_id, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMap,
    as: :build_transaction

  @impl true
  defdelegate handle_build_transaction(multi, command_map, repo),
    to: DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMap,
    as: :handle_build_transaction

  @doc """
  Processes an event map for transaction creation, returning a changeset on error.

  This function attempts to process the event map using OCC and entry validation. If the event is invalid (e.g., invalid entry data, duplicate source key, OCC timeout, or account mismatch), it returns an Ecto.Changeset with error details attached to the `:input_command_map` or other relevant fields. No partial data is saved on error.

  ## Returns
  - `{:ok, transaction, event}` on success
  - `{:error, changeset}` if validation or OCC fails (see changeset errors for details)
  - `{:error, string}` for unexpected errors
  """
  @spec process(TransactionCommandMap.t(), Ecto.Repo.t() | nil) ::
          CommandWorker.success_tuple()
          | {:errors, Changeset.t(TransactionCommandMap.t()) | String.t()}
  def process(%{action: :create_transaction} = command_map, repo \\ Repo) do
    case process_with_retry_no_save_on_error(command_map, repo) do
      {:error, :occ_timeout, %Changeset{data: %TransactionCommandMap{}} = changeset, _steps_so_far} ->
        warn("OCC timeout reached", command_map, changeset)

        {:error, changeset}

      response ->
        default_response_handler(response, command_map)
    end
  end

  @impl true
  def handle_occ_final_timeout(command_map, _repo) do
    command_map_changeset =
      command_map
      |> TransactionCommandMap.changeset(%{})
      |> Changeset.add_error(:occ_timeout, "OCC retries exhausted")

    Multi.new()
    |> Multi.error(:occ_timeout, command_map_changeset)
  end
end
