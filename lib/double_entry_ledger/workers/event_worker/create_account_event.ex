defmodule DoubleEntryLedger.Workers.EventWorker.CreateAccountEvent do
  @moduledoc """
   Processes :create_account actions
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [
      build_mark_as_processed: 1
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
  def process(%Event{event_map: %{action: :create_account}} = event) do
    build_create_account(event)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  @spec build_create_account(Event.t()) :: Ecto.Multi.t()
  defp build_create_account(
         %Event{event_map: %{payload: account_data} = event_map, instance_id: instance_id} = event
       ) do
    Multi.new()
    |> Multi.insert(:account, AccountStoreHelper.build_create(account_data, instance_id))
    |> Multi.insert(:journal_event, JournalEvent.build_create(%{event_map: event_map, instance_id: instance_id}))
    |> Multi.update(:event_success, build_mark_as_processed(event))
    |> Oban.insert(:create_account_link, fn %{event_success: event, account: account, journal_event: journal_event} ->
      Workers.Oban.CreateAccountLink.new(%{event_id: event.id, account_id: account.id, journal_event_id: journal_event.id})
    end)
  end
end
