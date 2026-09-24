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

  alias DoubleEntryLedger.{Command, JournalEvent}
  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.AccountStoreHelper
  alias DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler
  alias Ecto.Multi

  @doc "Runs the create-account command and returns the handler response."
  @spec process(Command.t()) :: AccountCommandResponseHandler.response()
  def process(%Command{command_map: %{action: :create_account}} = event) do
    build_create_account(event)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  # `:command_success` is a queue-row write, so this transaction is fenced on
  # the grant the command was claimed under exactly like the OCC pipeline's.
  # This module cannot inherit `Occ.Processor`'s `__using__` macro without
  # pulling in the whole OCC retry pipeline, so it fences through the shared
  # `Lease.lock_step/2` and `Lease.refresh_step/2` directly.
  @spec build_create_account(Command.t()) :: Ecto.Multi.t()
  defp build_create_account(
         %Command{
           command_map: %{payload: account_data} = command_map,
           instance_id: instance_id,
           lease_grant: grant
         } = event
       ) do
    Multi.new()
    |> Lease.lock_step(grant)
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
    |> Lease.refresh_step(grant)
  end
end
