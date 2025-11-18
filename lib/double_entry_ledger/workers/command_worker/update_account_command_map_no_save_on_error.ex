defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommandMapNoSaveOnError do
  @moduledoc """
  Processes AccountCommandMap structures for atomic update of events and their associated accounts.

  This module handles the update of accounts based on validated AccountCommandMap data within
  the Double Entry Ledger system. Unlike standard update event processors, this variant
  does not persist error states to the database, instead returning changesets with error
  details for client handling.

  ## Key Features

  * **Account Processing**: Handles update of accounts based on the event map's action
  * **Atomic Operations**: Ensures all event and account changes are performed in a single database transaction
  * **Error Handling**: Maps validation and dependency errors to appropriate changesets without persistence
  * **Optimistic Concurrency Control**: Integrates with OCC patterns for safe concurrent processing
  * **Dependency Resolution**: Locates original create events and their associated accounts

  ## Processing Flow

  1. **Command Creation**: Creates an Command record from the AccountCommandMap for audit purposes
  2. **Dependency Resolution**: Locates the original create account event and its account
  3. **Account Update**: Updates the account using the payload data
  4. **Command Completion**: Marks the event as processed upon successful account update
  5. **Linking**: Creates a link between the event and the updated account for traceability

  ## Error Handling

  The module provides comprehensive error handling:
  - Command validation errors are mapped back to AccountCommandMap changesets
  - Account validation errors are propagated to the event map payload
  - Dependency errors (missing create events) are handled gracefully
  - All errors are returned as changesets without database persistence
  - Database transaction ensures atomicity (all-or-nothing)

  ## Supported Actions

  Currently supports:
  - `:update_account` - Updates an existing account from AccountCommandMap payload

  ## Usage

  This module is designed for scenarios where error persistence should be managed
  externally, allowing clients to handle validation errors and retry logic according
  to their specific requirements.
  """

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [build_mark_as_processed: 1]

  import DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.Workers.CommandWorker.{AccountCommandMapResponseHandler}
  alias DoubleEntryLedger.Command.AccountCommandMap
  alias DoubleEntryLedger.{JournalEvent, Repo}
  alias DoubleEntryLedger.Stores.{AccountStoreHelper, CommandStoreHelper, InstanceStoreHelper}

  @doc """
  Processes an AccountCommandMap to update an existing account in the ledger system.

  This function orchestrates the update of both an Command record (for audit trail)
  and an Account record within a single database transaction. It first locates the
  original create account event and its associated account, then applies the updates
  from the event map's payload.

  ## Parameters

  * `command_map` - AccountCommandMap struct containing validated account update data.
    Must have `:update_account` action.

  ## Returns

  * `{:ok, Account.t(), Command.t()}` - Success tuple containing the updated Account and Command
  * `{:error, Changeset.t(AccountCommandMap.t())}` - AccountCommandMap changeset with validation errors
  * `{:error, String.t()}` - String error message for unexpected failures

  ## Transaction Steps

  1. Creates Command record from AccountCommandMap
  2. Locates original create account event and its account
  3. Updates Account record with payload data
  4. Marks Command as processed
  5. Creates Command-Account link for traceability

  ## Error Scenarios

  - Command validation errors → AccountCommandMap changeset with event-level errors
  - Missing create account event → AccountCommandMap changeset with dependency error
  - Account validation errors → AccountCommandMap changeset with payload-level errors
  - Other failures → String error message with details

  """
  @spec process(AccountCommandMap.t()) :: AccountCommandMapResponseHandler.response()
  def process(%AccountCommandMap{action: :update_account} = command_map) do
    build_update_account(command_map)
    |> handle_build_update_account(command_map)
    |> Repo.transaction()
    |> default_response_handler(command_map)
  end

  @spec build_update_account(AccountCommandMap.t()) :: Ecto.Multi.t()
  defp build_update_account(
         %AccountCommandMap{payload: payload, instance_address: iaddr, account_address: aaddr} =
           command_map
       )
       when not is_nil(iaddr) and not is_nil(aaddr) do
    Multi.new()
    |> Multi.one(:instance, InstanceStoreHelper.build_get_id_by_address(iaddr))
    |> Multi.insert(:new_command, fn %{instance: id} ->
      CommandStoreHelper.build_create(command_map, id)
    end)
    |> Multi.one(:get_account, AccountStoreHelper.get_by_address_query(iaddr, aaddr))
    |> Multi.merge(fn
      %{get_account: account} when not is_nil(account) ->
        Multi.update(Multi.new(), :account, AccountStoreHelper.build_update(account, payload))

      _ ->
        Multi.put(Multi.new(), :account, nil)
    end)
  end

  @spec handle_build_update_account(
          Ecto.Multi.t(),
          AccountCommandMap.t()
        ) :: Ecto.Multi.t()
  defp handle_build_update_account(multi, %AccountCommandMap{} = command_map) do
    Multi.merge(multi, fn
      %{account: %{id: aid}, new_command: %{id: eid, instance_id: iid} = event} ->
        Multi.insert(
          Multi.new(),
          :journal_event,
          JournalEvent.build_create(%{command_map: command_map, instance_id: iid})
        )
        |> Multi.update(:event_success, build_mark_as_processed(event))
        |> Oban.insert(:create_account_link, fn %{journal_event: %{id: jid}} ->
          Workers.Oban.JournalEventLinks.new(%{
            command_id: eid,
            account_id: aid,
            journal_event_id: jid
          })
        end)

      _ ->
        command_map_changeset =
          command_map
          |> AccountCommandMap.changeset(%{})
          |> Changeset.add_error(:create_account_event_error, to_string("Account does not exist"))

        Multi.error(Multi.new(), :create_account_event_error, command_map_changeset)
    end)
  end
end
