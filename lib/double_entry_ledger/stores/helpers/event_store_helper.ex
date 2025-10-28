defmodule DoubleEntryLedger.Stores.EventStoreHelper do
  @moduledoc """
  Helper functions for event processing in the Double Entry Ledger system.

  This module provides reusable utilities for working with events, focusing on common
  operations like building changesets, retrieving related events and transactions, and
  creating multi operations for use in Ecto transactions.

  ## Key Functionality

  * **Changeset Building**: Create Command changesets from TransactionEventMaps or AccountEventMaps
  * **Command Relationships**: Look up related events by source identifiers
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

  This module is primarily used internally by EventStore and CommandWorker modules to
  share common functionality and reduce code duplication.
  """
  import Ecto.Query, only: [from: 2, preload: 2, union: 2, subquery: 1]

  alias DoubleEntryLedger.Command.{TransactionEventMap, AccountEventMap}
  alias Ecto.Changeset
  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Command, Transaction, Account, Entry}
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateEventError

  @doc """
  Builds an Command changeset from a TransactionEventMap or AccountEventMap.

  Creates a new Command changeset suitable for database insertion, converting the
  provided event map structure into the appropriate Command attributes.

  ## Parameters

  * `event_map` - Either a TransactionEventMap or AccountEventMap struct containing event data

  ## Returns

  * `Ecto.Changeset.t(Command.t())` - A changeset for creating a new Command

  """
  @spec build_create(TransactionEventMap.t() | AccountEventMap.t(), Ecto.UUID.t()) ::
          Changeset.t(Command.t())
  def build_create(%TransactionEventMap{} = event_map, instance_id) do
    %Command{}
    |> Command.changeset(%{
      instance_id: instance_id,
      event_map: TransactionEventMap.to_map(event_map)
    })
  end

  def build_create(%AccountEventMap{} = event_map, instance_id) do
    %Command{}
    |> Command.changeset(%{instance_id: instance_id, event_map: AccountEventMap.to_map(event_map)})
  end

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

    - `Command.t() | nil`: The found event with preloaded associations, or nil if not found

  ## Preloaded Associations

  The returned event includes:
  - `:event_queue_item` - Processing status and retry information
  - `:account` - Associated account (for account-related events)
  - `transactions: [entries: :account]` - Transactions with their entries and accounts

  """
  @spec get_event_by(atom(), String.t(), String.t(), Ecto.UUID.t()) ::
          Command.t() | nil
  def get_event_by(action, source, source_idempk, instance_id) do
    from(e in Command,
      where:
        e.instance_id == ^instance_id and
          fragment("event_map->>? = ?", "action", ^Atom.to_string(action)) and
          fragment("event_map->>? = ?", "source", ^source) and
          fragment("event_map->>? = ?", "source_idempk", ^source_idempk),
      limit: 1,
      preload: [:event_queue_item, :account, transactions: [entries: :account]]
    )
    |> Repo.one()
  end

  @doc """
  Gets the transaction associated with a create transaction event.

  This function finds the original create transaction event corresponding to an update event
  and returns its associated transaction. Used primarily when processing update events
  to locate the original transaction to modify.

  ## Parameters

  * `event` - An Command struct containing source, source_idempk, and instance_id

  ## Returns

  * `{:ok, {Transaction.t(), Command.t()}}` - The transaction and create event if found and processed
  * Raises `UpdateEventError` if the create event doesn't exist or isn't processed

  """
  @spec get_create_transaction_event_transaction(Command.t()) ::
          {:ok, {Transaction.t(), Command.t()}}
          | {:error | :pending_error, String.t(), Command.t() | nil}
  def get_create_transaction_event_transaction(
        %{
          instance_id: id,
          event_map: %{
            source: source,
            source_idempk: source_idempk
          }
        } = event
      ) do
    case get_event_by(:create_transaction, source, source_idempk, id) do
      %{transactions: [transaction | _], event_queue_item: %{status: :processed}} =
          create_transaction_event ->
        {:ok, {transaction, create_transaction_event}}

      create_transaction_event ->
        raise UpdateEventError,
          create_event: create_transaction_event,
          update_event: event
    end
  end

  @doc """
  Gets the account associated with a create account event.

  This function finds the original create account event corresponding to an update event
  and returns its associated account. Used primarily when processing account update events
  to locate the original account to modify.

  ## Parameters

  * `event` - An Command struct containing source, source_idempk, and instance_id

  ## Returns

  * `{:ok, {Account.t(), Command.t()}}` - The account and create event if found and processed
  * Raises `UpdateEventError` if the create event doesn't exist or isn't processed

  """
  @spec get_create_account_event_account(Command.t()) ::
          {:ok, {Account.t(), Command.t()}}
          | {:error | :pending_error, String.t(), Command.t() | nil}
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
      %{account: account, event_queue_item: %{status: :processed}} =
          create_account_event ->
        {:ok, {account, create_account_event}}

      create_account_event ->
        raise UpdateEventError,
          create_event: create_account_event,
          update_event: event
    end
  end

  @doc """
  Builds an Ecto.Multi step to get a create transaction event's transaction.

  This function adds a step to an Ecto.Multi that retrieves the transaction associated with
  the create event corresponding to an update event. Handles error cases by wrapping
  exceptions in the result tuple.

  ## Parameters

  * `multi` - The Ecto.Multi instance to add the step to
  * `step` - The atom representing the step name in the Multi
  * `event_or_step` - Either an Command struct or the name of a previous step in the Multi

  ## Returns

  * `Ecto.Multi.t()` - The updated Multi instance with the new step added

  """
  @spec build_get_create_transaction_event_transaction(Ecto.Multi.t(), atom(), Command.t() | atom()) ::
          Ecto.Multi.t()
  def build_get_create_transaction_event_transaction(multi, step, event_or_step) do
    multi
    |> Multi.run(step, fn _, changes ->
      event = get_event(event_or_step, changes)

      try do
        {:ok, {transaction, _}} = get_create_transaction_event_transaction(event)
        {:ok, transaction}
      rescue
        e in UpdateEventError ->
          {:ok, {:error, e}}
      end
    end)
  end

  @spec base_transaction_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def base_transaction_query(transaction_id) do
    from(e in Command,
      join: evt in assoc(e, :event_transaction_links),
      where: evt.transaction_id == ^transaction_id,
      select: e
    )
    |> preload([:event_queue_item, transactions: :entries])
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
    from(e in Command,
      join: evt in assoc(e, :event_account_link),
      where: evt.account_id == ^account_id,
      select: e
    )
  end

  @spec transaction_events_for_account_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def transaction_events_for_account_query(account_id) do
    from(e in Command,
      join: t in assoc(e, :transactions),
      join: ety in Entry,
      on: ety.transaction_id == t.id,
      join: a in Account,
      on: a.id == ety.account_id,
      where: a.id == ^account_id,
      select: e
    )
  end

  @spec get_event(Command.t() | atom(), map()) :: Command.t()
  defp get_event(event_or_step, changes) do
    cond do
      is_struct(event_or_step, Command) -> event_or_step
      is_atom(event_or_step) -> Map.fetch!(changes, event_or_step)
    end
  end
end
