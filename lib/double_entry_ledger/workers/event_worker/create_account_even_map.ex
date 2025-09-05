defmodule DoubleEntryLedger.EventWorker.CreateAccountEventMap do
  @moduledoc """
  Processes event maps for creating accounts.
  """
  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [build_mark_as_processed: 1]

  alias Ecto.Multi
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Account, Event, EventStoreHelper, AccountStoreHelper, Repo}

  @spec process(AccountEventMap.t()) ::
          {:ok, Account.t(), Event.t()} | {:error, term()}
  def process(%AccountEventMap{action: :create_account} = event_map) do
    case build_account(event_map) |> Repo.transaction() do
      {:ok, %{create_account: account, event_success: event}} ->
        {:ok, account, event}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
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
