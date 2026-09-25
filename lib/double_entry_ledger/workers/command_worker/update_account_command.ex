defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommand do
  @moduledoc """
  Processes a stored `:update_account` command: updates the account, writes the
  journal event, and marks the command processed, or dead-letters it when the
  account does not exist.
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [
      build_mark_as_processed: 1,
      build_mark_as_dead_letter: 2
    ]

  import DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler,
    only: [default_response_handler: 2]

  alias DoubleEntryLedger.{Command, JournalEvent}
  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.AccountStoreHelper
  alias DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler
  alias Ecto.Multi

  @doc "Runs the update-account command and returns the handler response."
  @spec process(Command.t()) :: AccountCommandResponseHandler.response()
  def process(%Command{command_map: %{action: :update_account}} = event) do
    grant = Lease.grant_for(event)

    # The closing half of the fence belongs here rather than in
    # `build_update_account/2`, because the queue-row write is appended after
    # that builder returns, by `handle_build_update_account/2`. The refresh has
    # to be the last step of the transaction, so it goes on after it. The grant
    # is resolved once, here, and handed down: both halves must fence on the
    # same one.
    event
    |> build_update_account(grant)
    |> handle_build_update_account(event)
    |> Lease.refresh_step(grant)
    |> Repo.transaction()
    |> default_response_handler(event)
  end

  # Both branches of `handle_build_update_account/2` write the queue row
  # (`:command_success` or `:command_failure`), so this transaction is fenced
  # on the grant the command was claimed under exactly like the OCC pipeline's.
  # This module cannot inherit `Occ.Processor`'s `__using__` macro without
  # pulling in the whole OCC retry pipeline, so it takes the lease row lock
  # through the shared `Lease.lock_step/2` directly.
  @spec build_update_account(Command.t(), Lease.Grant.t() | nil) :: Ecto.Multi.t()
  defp build_update_account(
         %Command{
           command_map: %{payload: account_data, instance_address: iaddr, account_address: aaddr}
         },
         grant
       ) do
    Multi.new()
    |> Lease.lock_step(grant)
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
