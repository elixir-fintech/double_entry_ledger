defmodule DoubleEntryLedger.Workers.EventWorker.CreateAccountEvent do
  @moduledoc """
   Processes :create_account actions
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [
      build_mark_as_processed: 1,
      build_create_account_event_account_link: 2
    ]

  import DoubleEntryLedger.Workers.EventWorker.AccountEventResponseHandler,
    only: [default_response_handler: 2]

  alias DoubleEntryLedger.Event.AccountEventMap
  alias Ecto.Multi
  alias DoubleEntryLedger.{Event, Repo}
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
         %Event{event_map: %{payload: account_data}, instance_id: instance_id} = event
       ) do
    Multi.new()
    |> Multi.insert(:account, AccountStoreHelper.build_create(account_data, instance_id))
    |> Multi.update(:event_success, build_mark_as_processed(event))
    |> Multi.insert(:create_account_link, fn %{event_success: event, account: account} ->
      build_create_account_event_account_link(event, account)
    end)
  end
end
