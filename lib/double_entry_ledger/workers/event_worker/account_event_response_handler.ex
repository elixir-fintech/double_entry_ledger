defmodule DoubleEntryLedger.EventWorker.AccountEventResponseHandler do

  require Logger

  import DoubleEntryLedger.Event.TransferErrors,
    only: [
      from_event_to_event_map: 2,
      from_account_to_event_map_payload: 2,
      get_all_errors_with_opts: 1
    ]

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.Event

  @spec default_event_map_response_handler(
          {:ok, map()} | {:error, :atom, any(), map()},
          AccountEventMap.t(),
          String.t()
        ) ::
          EventWorker.success_tuple()
          | {:error, Changeset.t(AccountEventMap.t()) | String.t()}
  def default_event_map_response_handler(response, %AccountEventMap{} = event_map, module_name) do
    case response do
      {:ok, %{account: account, event_success: event}} ->
        Logger.info(
          "#{module_name}: processed successfully",
          Event.log_trace(event, account)
        )

        {:ok, account, event}

      {:error, :new_event, changeset, _changes} ->
        Logger.warning(
          "#{module_name}: Event changeset failed",
          AccountEventMap.log_trace(event_map, get_all_errors_with_opts(changeset))
        )

        {:error, from_event_to_event_map(event_map, changeset)}

      {:error, :account, changeset, _changes} ->
        Logger.warning(
          "#{module_name}: Account changeset failed",
          AccountEventMap.log_trace(event_map, get_all_errors_with_opts(changeset))
        )

        {:error, from_account_to_event_map_payload(event_map, changeset)}

      {:error, step, error, _steps_so_far} ->
        message = "#{module_name}: Step :#{step} failed."

        Logger.error(
          message,
          AccountEventMap.log_trace(event_map, error)
        )

        {:error, "#{message} #{inspect(error)}"}
    end
  end
end
