defmodule DoubleEntryLedger.EventWorker.CreateEventMapNoSaveOnError do
  @moduledoc """
  TODO
  """

  use DoubleEntryLedger.Occ.Processor

  import DoubleEntryLedger.EventWorker.ResponseHandler,
    only: [default_process_response_handler: 3]

  alias DoubleEntryLedger.{
    Event,
    Transaction,
    Repo
  }

  alias DoubleEntryLedger.Event.EventMap

  alias Ecto.Changeset

  @impl true
  defdelegate handle_transaction_map_error(event_map, error, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_transaction_map_error

  @impl true
  defdelegate handle_occ_final_timeout(event_map, repo),
    to: DoubleEntryLedger.EventWorker.ResponseHandler,
    as: :handle_occ_final_timeout

  @impl true
  defdelegate build_transaction(event_map, transaction_map, repo),
    to: DoubleEntryLedger.EventWorker.CreateEventMap,
    as: :build_transaction

  @impl true
  defdelegate handle_build_transaction(multi, event_map, repo),
    to: DoubleEntryLedger.EventWorker.CreateEventMap,
    as: :handle_build_transaction

  @spec process(DoubleEntryLedger.Event.EventMap.t()) ::
          {:error, nonempty_binary() | Ecto.Changeset.t()}
          | {:ok, DoubleEntryLedger.Transaction.t(), DoubleEntryLedger.Event.t()}
  @doc """
  """
  @spec process(EventMap.t(), Ecto.Repo.t() | nil) ::
          {:ok, Transaction.t(), Event.t()} | {:error, Event.t() | Changeset.t() | String.t()}
  def process(%{action: :create} = event_map, repo \\ Repo) do
    case process_with_retry_no_save_on_error(event_map, repo) do
      {:error, :occ_timeout, %Changeset{data: %EventMap{}} = changeset, _steps_so_far} ->
        Logger.warning(
          "#{@module_name}: OCC timeout reached",
          EventMap.log_trace(event_map, changeset)
        )

        {:error, changeset}

      response ->
        default_process_response_handler(response, event_map, @module_name)
    end
  end
end
