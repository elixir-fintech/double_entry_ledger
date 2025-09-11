defmodule DoubleEntryLedger.EventWorker.CreateAccountEventMapNoSaveOnError do
  @moduledoc """
  Processes event maps for creating accounts.
  """
  require Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [build_mark_as_processed: 1, build_create_account_event_account_link: 2]

  import DoubleEntryLedger.Event.TransferErrors,
    only: [
      from_event_to_event_map: 2,
      from_account_to_event_map_payload: 2,
      get_all_errors_with_opts: 1
    ]

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Account, Event, EventStoreHelper, AccountStoreHelper, Repo}

  @module_name __MODULE__ |> Module.split() |> List.last()

  @spec process(AccountEventMap.t()) ::
          {:ok, Account.t(), Event.t()} | {:error, Changeset.t(AccountEventMap.t()) | String.t()}
  def process(%AccountEventMap{action: :create_account} = event_map) do
    case build_account(event_map) |> Repo.transaction() do
      {:ok, %{create_account: account, event_success: event}} ->
        Logger.info(
          "#{@module_name}: processed successfully",
          Event.log_trace(event, account)
        )

        {:ok, account, event}

      {:error, :new_event, changeset, _changes} ->
        Logger.warning(
          "#{@module_name}: Event changeset failed",
          AccountEventMap.log_trace(event_map, get_all_errors_with_opts(changeset))
        )

        {:error, from_event_to_event_map(event_map, changeset)}

      {:error, :create_account, changeset, _changes} ->
        Logger.warning(
          "#{@module_name}: Account changeset failed",
          AccountEventMap.log_trace(event_map, get_all_errors_with_opts(changeset))
        )

        {:error, from_account_to_event_map_payload(event_map, changeset)}

      {:error, step, error, _steps_so_far} ->
        message = "AccountEventMap: Step :#{step} failed."

        Logger.error(
          message,
          AccountEventMap.log_trace(event_map, error)
        )

        {:error, "#{message} #{inspect(error)}"}
    end
  end

  @spec build_account(AccountEventMap.t()) :: Ecto.Multi.t()
  def build_account(%AccountEventMap{payload: payload, instance_id: instance_id} = event_map) do
    Multi.new()
    |> Multi.insert(:new_event, EventStoreHelper.build_create(event_map))
    |> Multi.insert(:create_account, AccountStoreHelper.build_create(payload, instance_id))
    |> Multi.update(:event_success, fn %{new_event: event} ->
      build_mark_as_processed(event)
    end)
    |> Multi.insert(:create_account_link, fn %{event_success: event, create_account: account} ->
      build_create_account_event_account_link(event, account)
    end)
  end
end
