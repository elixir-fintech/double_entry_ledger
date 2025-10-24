defmodule DoubleEntryLedger.Stores.JournalEventStoreHelper do
  @moduledoc """
  Helper functions for event processing in the Double Entry Ledger system.

  This module provides reusable utilities for working with events, focusing on common
  operations like building changesets, retrieving related events and transactions, and
  creating multi operations for use in Ecto transactions.

  ## Key Functionality

  * **Changeset Building**: Create Event changesets from TransactionEventMaps or AccountEventMaps
  * **Event Relationships**: Look up related events by source identifiers
  * **Transaction Linking**: Find transactions and accounts associated with events
  * **Ecto.Multi Integration**: Build multi operations for atomic database transactions
  * **Status Management**: Create changesets to update event status and error information

  ## Usage Examples

  Building a changeset from an EventMap:

      event_changeset = EventStoreHelper.build_create(event_map)

  Adding a step to get a create event's transaction:

      multi =
        Ecto.Multi.new()
        |> EventStoreHelper.build_get_create_transaction_event_transaction(:transaction, update_event)
        |> Ecto.Multi.update(:event, fn %{transaction: transaction} ->
          EventStoreHelper.build_mark_as_processed(update_event, transaction.id)
        end)

  ## Implementation Notes

  This module is primarily used internally by EventStore and EventWorker modules to
  share common functionality and reduce code duplication.
  """
  import Ecto.Query, only: [from: 2, subquery: 1, union: 2]

  alias DoubleEntryLedger.{Repo, Event, JournalEvent, Account, Entry}
  alias DoubleEntryLedger.Workers.EventWorker.UpdateEventError

  @doc """
  Retrieves an event by its action and source identifiers with preloaded associations.

  This function looks up an event using i
      event_map
      |> TransactionEventMap.to_map()
      |> Map.put(:instance_id, instance_id)
      |> Mts action, source system identifier,
  source-specific identifier, and instance ID. The returned event includes preloaded
  associations for event_queue_item, account, and transactions with their entries.

  ## Parameters

    - `action`: The event action atom (e.g., `:create_transaction`, `:create_account`)
    - `source`: The source system identifier (e.g., "accounting_system", "api")
    - `source_idempk`: The source-specific identifier (e.g., "invoice_123", "tx_456")
    - `instance_id`: The instance UUID that groups related events

  ## Returns

    - `Event.t() | nil`: The found event with preloaded associations, or nil if not found

  ## Preloaded Associations

  The returned event includes:
  - `:event_queue_item` - Processing status and retry information
  - `:account` - Associated account (for account-related events)
  - `transactions: [entries: :account]` - Transactions with their entries and accounts

  """
  @spec get_event_by(atom(), String.t(), String.t(), Ecto.UUID.t()) ::
          JournalEvent.t() | nil
  def get_event_by(action, source, source_idempk, instance_id) do
    from(e in JournalEvent,
      where:
        e.instance_id == ^instance_id and
          fragment("event_map->>? = ?", "action", ^Atom.to_string(action)) and
          fragment("event_map->>? = ?", "source", ^source) and
          fragment("event_map->>? = ?", "source_idempk", ^source_idempk),
      limit: 1,
      preload: [:account]
    )
    |> Repo.one()
  end

  @doc """
  Gets the account associated with a create account event.

  This function finds the original create account event corresponding to an update event
  and returns its associated account. Used primarily when processing account update events
  to locate the original account to modify.

  ## Parameters

  * `event` - An Event struct containing source, source_idempk, and instance_id

  ## Returns

  * `{:ok, {Account.t(), Event.t()}}` - The account and create event if found and processed
  * Raises `UpdateEventError` if the create event doesn't exist or isn't processed

  """
  @spec get_create_account_event_account(Event.t()) ::
          {:ok, {Account.t(), JournalEvent.t()}}
          | {:error | :pending_error, String.t(), JournalEvent.t() | nil}
  def get_create_account_event_account(
        %{
          instance_id: id,
          event_map: %{
            source: source,
            source_idempk: source_idempk
          }
        } = event
      ) do
    case get_event_by(:create_account, source, source_idempk, id) do
      %{account: account} = create_account_event ->
        {:ok, {account, create_account_event}}

      create_account_event ->
        raise UpdateEventError,
          create_event: create_account_event,
          update_event: event
    end
  end

  @spec all_processed_events_for_account_id(Ecto.UUID.t()) :: Ecto.Query.t()
  def all_processed_events_for_account_id(account_id) do
    union =
      base_account_query(account_id)
      |> union(^transaction_events_for_account_query(account_id))

    from(u in subquery(union),
      order_by: [desc: u.inserted_at]
    )
  end

  @spec base_account_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def base_account_query(account_id) do
    from(je in JournalEvent,
      join: evt in assoc(je, :event_account_link),
      where: evt.account_id == ^account_id,
      select: je
    )
  end

  @spec transaction_events_for_account_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def transaction_events_for_account_query(account_id) do
    from(je in JournalEvent,
      join: t in assoc(je, :transaction),
      join: ety in Entry,
      on: ety.transaction_id == t.id,
      join: a in Account,
      on: a.id == ety.account_id,
      where: a.id == ^account_id,
      select: je
    )
  end

  @spec base_transaction_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def base_transaction_query(transaction_id) do
    from(je in JournalEvent,
      join: evt in assoc(je, :event_transaction_link),
      where: evt.transaction_id == ^transaction_id,
      select: je,
      preload: [transaction: :entries]
    )
  end
end
