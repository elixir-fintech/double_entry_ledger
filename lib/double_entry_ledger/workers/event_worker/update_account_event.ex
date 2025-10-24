defmodule DoubleEntryLedger.Workers.EventWorker.UpdateAccountEvent do
  @moduledoc """
  UpdateAccountEvent
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [
      build_mark_as_processed: 1,
      build_mark_as_dead_letter: 2
    ]

  import DoubleEntryLedger.Workers.EventWorker.AccountEventResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Event, JournalEvent, Repo}
  alias DoubleEntryLedger.Stores.AccountStoreHelper
  alias DoubleEntryLedger.Workers.EventWorker.AccountEventResponseHandler

  @spec process(Event.t()) :: AccountEventResponseHandler.response()
  def process(%Event{event_map: %{action: :update_account}} = event) do
    build_update_account(event)
    |> handle_build_update_account(event)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  @spec build_update_account(Event.t()) :: Ecto.Multi.t()
  defp build_update_account(%Event{event_map: %{payload: account_data, instance_address: iaddr, account_address: aaddr}}) do
    Multi.new()
    |> Multi.one(:_get_account, AccountStoreHelper.get_by_address_query(iaddr, aaddr))
    |> Multi.merge(fn
      %{_get_account: account} when not is_nil(account) ->
        Multi.update(Multi.new(), :account, AccountStoreHelper.build_update(account, account_data))

      _ ->
        Multi.put(Multi.new(), :account, nil)
      end)
  end

  @spec handle_build_update_account(
          Ecto.Multi.t(),
          Event.t()
        ) :: Ecto.Multi.t()
  defp handle_build_update_account(multi, %Event{event_map: event_map, instance_id: id} = event) do
    Multi.merge(multi, fn
      %{account: %{id: aid}} ->
        Multi.insert(Multi.new(), :journal_event, fn _ ->
          JournalEvent.build_create(%{event_map: event_map, instance_id: id})
        end)
        |> Multi.update(:event_success, build_mark_as_processed(event))
        |> Oban.insert(:create_account_link, fn %{journal_event: %{id: jid}} ->
          Workers.Oban.CreateAccountLink.new(%{event_id: event.id, account_id: aid, journal_event_id: jid})
        end)

      _ ->
        Multi.update(Multi.new(), :event_failure, build_mark_as_dead_letter(event, "Account does not exist"))
    end)
  end
end
