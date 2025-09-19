defmodule DoubleEntryLedger.EventWorker.CreateAccountEventMapNoSaveOnError do
  @moduledoc """
  Processes AccountEventMap for creating new accounts in the double-entry ledger system.

  This worker handles the creation of accounts based on validated AccountEventMap data.
  It coordinates the creation of both the Event record (for audit trail) and the Account
  record (the actual ledger account) within a single database transaction.

  Unlike standard event processors, this module does not persist error states to the database.
  Instead, it returns validation errors as changesets for client handling, making it suitable
  for scenarios where error persistence should be managed externally.

  ## Processing Flow

  1. **Event Creation**: Creates an Event record from the AccountEventMap for audit purposes
  2. **Account Creation**: Creates the Account record using the payload data
  3. **Event Completion**: Marks the event as processed upon successful account creation
  4. **Linking**: Creates a link between the event and the created account for traceability

  ## Error Handling

  The module provides detailed error handling and logging:
  - Event validation errors are mapped back to AccountEventMap changesets
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
  - `:create_account` - Creates a new account from AccountEventMap payload
  """

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [build_mark_as_processed: 1, build_create_account_event_account_link: 2]

  import DoubleEntryLedger.EventWorker.AccountEventResponseHandler,
    only: [default_event_map_response_handler: 3]

  alias Ecto.Multi
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.EventWorker.AccountEventResponseHandler
  alias DoubleEntryLedger.{InstanceStoreHelper, EventStoreHelper, AccountStoreHelper, Repo}

  @module_name __MODULE__ |> Module.split() |> List.last()

  @doc """
  Processes an AccountEventMap to create a new account in the ledger system.

  This function orchestrates the creation of both an Event record (for audit trail)
  and an Account record within a single database transaction. Upon successful completion,
  the event is marked as processed and linked to the created account.

  ## Parameters

    - `event_map`: AccountEventMap struct containing validated account creation data.
      Must have `:create_account` action.

  ## Returns

    - `{:ok, account, event}` - Success tuple containing the created Account and Event
    - `{:error, changeset}` - AccountEventMap changeset with validation errors when
      event or account creation fails
    - `{:error, message}` - String error message for unexpected failures

  ## Transaction Steps

  1. Creates Event record from AccountEventMap
  2. Creates Account record from payload data
  3. Marks Event as processed
  4. Creates Event-Account link for traceability

  ## Error Mapping

  - Event validation errors → AccountEventMap changeset with event-level errors
  - Account validation errors → AccountEventMap changeset with payload-level errors
  - Other failures → String error message with details

  ## Examples

      # Successful account creation
      iex> alias DoubleEntryLedger.Event.AccountEventMap
      iex> alias DoubleEntryLedger.{Account, Event}
      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{address: "Main:Instance"})
      iex> event_map = %AccountEventMap{
      ...>   action: :create_account,
      ...>   source: "test_suite",
      ...>   source_idempk: "unique_id_123",
      ...>   instance_address: instance.address,
      ...>   payload: %AccountData{
      ...>     name: "Cash Account",
      ...>     type: :asset,
      ...>     currency: :USD
      ...>   }
      ...> }
      iex> {:ok, account, event} = CreateAccountEventMapNoSaveOnError.process(event_map)
      iex> is_struct(account, Account) and account.name == "Cash Account" and is_struct(event, Event) and event.event_queue_item.status == :processed
      true

      iex> alias DoubleEntryLedger.Event.AccountEventMap
      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{address: "Main:Instance"})
      iex> invalid_event_map = %AccountEventMap{
      ...>   action: :create_account,
      ...>   source: "test_suite",
      ...>   source_idempk: "unique_id_124",
      ...>   instance_address: instance.address,
      ...>   payload: %AccountData{name: "", type: nil}  # missing required fields
      ...> }
      iex> {:error, changeset} = CreateAccountEventMapNoSaveOnError.process(invalid_event_map)
      iex> changeset.valid?
      false
  """
  @spec process(AccountEventMap.t()) :: AccountEventResponseHandler.response()
  def process(%AccountEventMap{action: :create_account} = event_map) do
    build_create_account(event_map)
    |> Repo.transaction()
    |> default_event_map_response_handler(event_map, @module_name)
  end

  @spec build_create_account(AccountEventMap.t()) :: Ecto.Multi.t()
  defp build_create_account(
         %AccountEventMap{payload: payload, instance_address: address} = event_map
       ) do
    Multi.new()
    |> Multi.one(:instance, InstanceStoreHelper.build_get_by_address(address))
    |> Multi.insert(:new_event, fn %{instance: %{id: id}} -> EventStoreHelper.build_create(event_map, id) end)
    |> Multi.insert(:account, fn %{instance: %{id: id}} -> AccountStoreHelper.build_create(payload, id) end)
    |> Multi.update(:event_success, fn %{new_event: event} ->
      build_mark_as_processed(event)
    end)
    |> Multi.insert(:create_account_link, fn %{event_success: event, account: account} ->
      build_create_account_event_account_link(event, account)
    end)
  end
end
