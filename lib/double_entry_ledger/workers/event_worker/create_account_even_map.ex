defmodule DoubleEntryLedger.EventWorker.CreateAccountEventMap do
  @moduledoc """
  Processes event maps for creating accounts.
  """
  require Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [build_mark_as_processed: 1]

  import DoubleEntryLedger.Event.TransferErrors,
    only: [transfer_errors_from_event_to_event_map: 2, transfer_errors_from_account_to_event_map: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Account, Event, EventStoreHelper, AccountStoreHelper, Repo}

  @spec process(AccountEventMap.t()) ::
          {:ok, Account.t(), Event.t()} | {:error, term()}
  def process(%AccountEventMap{action: :create_account} = event_map) do
    case build_account(event_map) |> Repo.transaction() do
      {:ok, %{create_account: account, event_success: event}} ->
        {:ok, account, event}

      {:error, :new_event, changeset, _changes} ->
        {:error, transfer_errors_from_event_to_event_map(event_map, changeset)}

      {:error, :create_account, changeset, _changes} ->
        {:error, transfer_errors_from_account_to_event_map(event_map, changeset)}

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
  end

end
