defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateAccountEventMapNoSaveOnError do
  @moduledoc """
  Processes AccountEventMap structures for atomic update of events and their associated accounts.

  This module handles the update of accounts based on validated AccountEventMap data within
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

  1. **Command Creation**: Creates an Command record from the AccountEventMap for audit purposes
  2. **Dependency Resolution**: Locates the original create account event and its account
  3. **Account Update**: Updates the account using the payload data
  4. **Command Completion**: Marks the event as processed upon successful account update
  5. **Linking**: Creates a link between the event and the updated account for traceability

  ## Error Handling

  The module provides comprehensive error handling:
  - Command validation errors are mapped back to AccountEventMap changesets
  - Account validation errors are propagated to the event map payload
  - Dependency errors (missing create events) are handled gracefully
  - All errors are returned as changesets without database persistence
  - Database transaction ensures atomicity (all-or-nothing)

  ## Supported Actions

  Currently supports:
  - `:update_account` - Updates an existing account from AccountEventMap payload

  ## Usage

  This module is designed for scenarios where error persistence should be managed
  externally, allowing clients to handle validation errors and retry logic according
  to their specific requirements.
  """

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [build_mark_as_processed: 1]

  import DoubleEntryLedger.Workers.CommandWorker.AccountEventMapResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.Workers.CommandWorker.{AccountEventMapResponseHandler}
  alias DoubleEntryLedger.Command.AccountEventMap
  alias DoubleEntryLedger.{JournalEvent, Repo}
  alias DoubleEntryLedger.Stores.{AccountStoreHelper, CommandStoreHelper, InstanceStoreHelper}

  @doc """
  Processes an AccountEventMap to update an existing account in the ledger system.

  This function orchestrates the update of both an Command record (for audit trail)
  and an Account record within a single database transaction. It first locates the
  original create account event and its associated account, then applies the updates
  from the event map's payload.

  ## Parameters

  * `event_map` - AccountEventMap struct containing validated account update data.
    Must have `:update_account` action.

  ## Returns

  * `{:ok, Account.t(), Command.t()}` - Success tuple containing the updated Account and Command
  * `{:error, Changeset.t(AccountEventMap.t())}` - AccountEventMap changeset with validation errors
  * `{:error, String.t()}` - String error message for unexpected failures

  ## Transaction Steps

  1. Creates Command record from AccountEventMap
  2. Locates original create account event and its account
  3. Updates Account record with payload data
  4. Marks Command as processed
  5. Creates Command-Account link for traceability

  ## Error Scenarios

  - Command validation errors → AccountEventMap changeset with event-level errors
  - Missing create account event → AccountEventMap changeset with dependency error
  - Account validation errors → AccountEventMap changeset with payload-level errors
  - Other failures → String error message with details

  """
  @spec process(AccountEventMap.t()) :: AccountEventMapResponseHandler.response()
  def process(%AccountEventMap{action: :update_account} = event_map) do
    build_update_account(event_map)
    |> handle_build_update_account(event_map)
    |> Repo.transaction()
    |> default_response_handler(event_map)
  end

  @spec build_update_account(AccountEventMap.t()) :: Ecto.Multi.t()
  defp build_update_account(
         %AccountEventMap{payload: payload, instance_address: iaddr, account_address: aaddr} =
           event_map
       )
       when not is_nil(iaddr) and not is_nil(aaddr) do
    Multi.new()
    |> Multi.one(:instance, InstanceStoreHelper.build_get_id_by_address(iaddr))
    |> Multi.insert(:new_event, fn %{instance: id} ->
      CommandStoreHelper.build_create(event_map, id)
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
          AccountEventMap.t()
        ) :: Ecto.Multi.t()
  defp handle_build_update_account(multi, %AccountEventMap{} = event_map) do
    Multi.merge(multi, fn
      %{account: %{id: aid}, new_event: %{id: eid, instance_id: iid} = event} ->
        Multi.insert(
          Multi.new(),
          :journal_event,
          JournalEvent.build_create(%{event_map: event_map, instance_id: iid})
        )
        |> Multi.update(:event_success, build_mark_as_processed(event))
        |> Oban.insert(:create_account_link, fn %{journal_event: %{id: jid}} ->
          Workers.Oban.CreateAccountLink.new(%{
            command_id: eid,
            account_id: aid,
            journal_event_id: jid
          })
        end)

      _ ->
        event_map_changeset =
          event_map
          |> AccountEventMap.changeset(%{})
          |> Changeset.add_error(:create_account_event_error, to_string("Account does not exist"))

        Multi.error(Multi.new(), :create_account_event_error, event_map_changeset)
    end)
  end
end
