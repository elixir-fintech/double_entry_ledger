defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommand do
  @moduledoc """
  UpdateAccountCommand
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [
      build_mark_as_processed: 1,
      build_mark_as_dead_letter: 2
    ]

  import DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.{Command, JournalEvent}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.AccountStoreHelper
  alias DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler

  @spec process(Command.t()) :: AccountCommandResponseHandler.response()
  def process(%Command{command_map: %{action: :update_account}} = event) do
    build_update_account(event)
    |> handle_build_update_account(event)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  @spec build_update_account(Command.t()) :: Ecto.Multi.t()
  defp build_update_account(%Command{
         command_map: %{payload: account_data, instance_address: iaddr, account_address: aaddr}
       }) do
    Multi.new()
    |> Multi.one(:_get_account, AccountStoreHelper.get_by_address_query(iaddr, aaddr))
    |> Multi.merge(fn
      %{_get_account: account} when not is_nil(account) ->
        Multi.update(
          Multi.new(),
          :account,
          AccountStoreHelper.build_update(account, account_data)
        )

      _ ->
        Multi.put(Multi.new(), :account, nil)
    end)
  end

  @spec handle_build_update_account(
          Ecto.Multi.t(),
          Command.t()
        ) :: Ecto.Multi.t()
  defp handle_build_update_account(
         multi,
         %Command{command_map: command_map, instance_id: id} = event
       ) do
    Multi.merge(multi, fn
      %{account: %{id: aid}} ->
        Multi.insert(Multi.new(), :journal_event, fn _ ->
          JournalEvent.build_create(%{
            command_map: command_map,
            instance_id: id,
            command_id: event.id,
            account_id: aid
          })
        end)
        |> Multi.update(:command_success, build_mark_as_processed(event))

      _ ->
        Multi.update(
          Multi.new(),
          :command_failure,
          build_mark_as_dead_letter(event, "Account does not exist")
        )
    end)
  end
end
