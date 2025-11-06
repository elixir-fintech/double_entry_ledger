defmodule DoubleEntryLedger.Workers.CommandWorker.CreateAccountEvent do
  @moduledoc """
   Processes :create_account actions
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [
      build_mark_as_processed: 1
    ]

  import DoubleEntryLedger.Workers.CommandWorker.AccountEventResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.{Command, JournalEvent, Repo}
  alias DoubleEntryLedger.Stores.AccountStoreHelper
  alias DoubleEntryLedger.Workers.CommandWorker.AccountEventResponseHandler

  @spec process(Command.t()) :: AccountEventResponseHandler.response()
  def process(%Command{event_map: %{action: :create_account}} = event) do
    build_create_account(event)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  @spec build_create_account(Command.t()) :: Ecto.Multi.t()
  defp build_create_account(
         %Command{event_map: %{payload: account_data} = event_map, instance_id: instance_id} =
           event
       ) do
    Multi.new()
    |> Multi.insert(:account, AccountStoreHelper.build_create(account_data, instance_id))
    |> Multi.insert(
      :journal_event,
      JournalEvent.build_create(%{event_map: event_map, instance_id: instance_id})
    )
    |> Multi.update(:event_success, build_mark_as_processed(event))
    |> Oban.insert(:create_account_link, fn %{
                                              event_success: event,
                                              account: account,
                                              journal_event: journal_event
                                            } ->
      Workers.Oban.JournalEventLinks.new(%{
        command_id: event.id,
        account_id: account.id,
        journal_event_id: journal_event.id
      })
    end)
  end
end
