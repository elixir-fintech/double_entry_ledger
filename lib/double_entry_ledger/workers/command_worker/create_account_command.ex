defmodule DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommand do
  @moduledoc """
  Processes a stored `:create_account` command: inserts the account, writes the
  journal event, and marks the command processed in one transaction.
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [
      build_mark_as_processed: 1
    ]

  import DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.{Command, JournalEvent}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.AccountStoreHelper
  alias DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler

  @doc "Runs the create-account command and returns the handler response."
  @spec process(Command.t()) :: AccountCommandResponseHandler.response()
  def process(%Command{command_map: %{action: :create_account}} = event) do
    build_create_account(event)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  @spec build_create_account(Command.t()) :: Ecto.Multi.t()
  defp build_create_account(
         %Command{command_map: %{payload: account_data} = command_map, instance_id: instance_id} =
           event
       ) do
    Multi.new()
    |> Multi.insert(:account, AccountStoreHelper.build_create(account_data, instance_id))
    |> Multi.insert(:journal_event, fn %{account: account} ->
      JournalEvent.build_create(%{
        command_map: command_map,
        instance_id: instance_id,
        command_id: event.id,
        account_id: account.id
      })
    end)
    |> Multi.update(:command_success, build_mark_as_processed(event))
  end
end
