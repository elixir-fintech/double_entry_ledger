defmodule DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommandMapNoSaveOnError do
  @moduledoc """
  Processes AccountCommandMap for creating new accounts in the double-entry ledger system.

  This worker handles the creation of accounts based on validated AccountCommandMap data.
  It coordinates the creation of both the Command record (for audit trail) and the Account
  record (the actual ledger account) within a single database transaction.

  Unlike standard event processors, this module does not persist error states to the database.
  Instead, it returns validation errors as changesets for client handling, making it suitable
  for scenarios where error persistence should be managed externally.

  ## Processing Flow

  1. **Command Creation**: Creates an Command record from the AccountCommandMap for audit purposes
  2. **Account Creation**: Creates the Account record using the payload data
  3. **Command Completion**: Marks the event as processed upon successful account creation
  4. **Linking**: Creates a link between the event and the created account for traceability

  ## Error Handling

  The module provides detailed error handling and logging:
  - Command validation errors are mapped back to AccountCommandMap changesets
  - Account validation errors are propagated to the event map payload
  - All processing steps are logged with appropriate trace information
  - Database transaction ensures atomicity (all-or-nothing)
  - Errors are returned as changesets rather than persisted to the database

  ## Key Features

  - **Transactional Safety**: Uses Ecto.Multi for atomic operations
  - **Error Propagation**: Maps validation errors back to appropriate changeset structures
  - **Audit Trail**: Creates event records for all account creation attempts
  - **Traceability**: Links events to created accounts for audit purposes
  - **No Error Persistence**: Returns error changesets without database persistence

  ## Supported Actions

  Currently supports:
  - `:create_account` - Creates a new account from AccountCommandMap payload
  """

  import DoubleEntryLedger.CommandQueue.Scheduling,
    only: [build_mark_as_processed: 1]

  import DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandler,
    only: [default_response_handler: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.Command.AccountCommandMap
  alias DoubleEntryLedger.Workers
  alias DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandler
  alias DoubleEntryLedger.{JournalEvent, Repo}
  alias DoubleEntryLedger.Stores.{InstanceStoreHelper, CommandStoreHelper, AccountStoreHelper}

  @doc """
  Processes an AccountCommandMap to create a new account in the ledger system.

  This function orchestrates the creation of both an Command record (for audit trail)
  and an Account record within a single database transaction. Upon successful completion,
  the event is marked as processed and linked to the created account.

  ## Parameters

    - `event_map`: AccountCommandMap struct containing validated account creation data.
      Must have `:create_account` action.

  ## Returns

    - `{:ok, account, event}` - Success tuple containing the created Account and Command
    - `{:error, changeset}` - AccountCommandMap changeset with validation errors when
      event or account creation fails
    - `{:error, message}` - String error message for unexpected failures

  ## Transaction Steps

  1. Creates Command record from AccountCommandMap
  2. Creates Account record from payload data
  3. Marks Command as processed
  4. Creates Command-Account link for traceability

  ## Error Mapping

  - Command validation errors → AccountCommandMap changeset with event-level errors
  - Account validation errors → AccountCommandMap changeset with payload-level errors
  - Other failures → String error message with details

  ## Examples

      # Successful account creation
      iex> {:ok, instance} = InstanceStore.create(%{address: "Main:Instance"})
      iex> event_map = %AccountCommandMap{
      ...>   action: :create_account,
      ...>   source: "test_suite",
      ...>   instance_address: instance.address,
      ...>   payload: %AccountData{
      ...>     name: "Cash Account",
      ...>     address: "account:main",
      ...>     type: :asset,
      ...>     currency: :USD
      ...>   }
      ...> }
      iex> {:ok, account, event} = CreateAccountCommandMapNoSaveOnError.process(event_map)
      iex> is_struct(account, Account) and account.name == "Cash Account" and is_struct(event, Command) and event.command_queue_item.status == :processed
      true

      iex> {:ok, instance} = InstanceStore.create(%{address: "Main:Instance"})
      iex> invalid_event_map = %AccountCommandMap{
      ...>   action: :create_account,
      ...>   source: "test_suite",
      ...>   instance_address: instance.address,
      ...>   payload: %AccountData{name: "", type: nil}  # missing required fields
      ...> }
      iex> {:error, changeset} = CreateAccountCommandMapNoSaveOnError.process(invalid_event_map)
      iex> changeset.valid?
      false
  """
  @spec process(AccountCommandMap.t()) :: AccountCommandMapResponseHandler.response()
  def process(%AccountCommandMap{action: :create_account} = event_map) do
    build_create_account(event_map)
    |> Repo.transaction()
    |> default_response_handler(event_map)
  end

  @spec build_create_account(AccountCommandMap.t()) :: Ecto.Multi.t()
  defp build_create_account(
         %AccountCommandMap{payload: payload, instance_address: address} = event_map
       ) do
    Multi.new()
    |> Multi.one(:instance, InstanceStoreHelper.build_get_id_by_address(address))
    |> Multi.insert(:new_command, fn %{instance: id} ->
      CommandStoreHelper.build_create(event_map, id)
    end)
    |> Multi.insert(:journal_event, fn %{instance: id} ->
      JournalEvent.build_create(%{event_map: event_map, instance_id: id})
    end)
    |> Multi.insert(:account, fn %{instance: id} ->
      AccountStoreHelper.build_create(payload, id)
    end)
    |> Multi.update(:event_success, fn %{new_command: event} ->
      build_mark_as_processed(event)
    end)
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
