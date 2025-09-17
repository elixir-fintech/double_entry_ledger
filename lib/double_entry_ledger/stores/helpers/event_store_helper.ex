defmodule DoubleEntryLedger.EventStoreHelper do
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
  alias DoubleEntryLedger.Event.{TransactionEventMap, AccountEventMap}
  alias Ecto.Changeset
  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Event, Transaction}
  alias DoubleEntryLedger.EventWorker.UpdateEventError

  @doc """
  Builds an Event changeset from a TransactionEventMap or AccountEventMap.

  Creates a new Event changeset suitable for database insertion, converting the
  provided event map structure into the appropriate Event attributes.

  ## Parameters

  * `event_map` - Either a TransactionEventMap or AccountEventMap struct containing event data

  ## Returns

  * `Ecto.Changeset.t(Event.t())` - A changeset for creating a new Event

  """
  @spec build_create(TransactionEventMap.t() | AccountEventMap.t()) :: Changeset.t(Event.t())
  def build_create(%TransactionEventMap{} = event_map) do
    %Event{}
    |> Event.changeset(TransactionEventMap.to_map(event_map))
  end

  def build_create(%AccountEventMap{} = event_map) do
    %Event{}
    |> Event.changeset(AccountEventMap.to_map(event_map))
  end

  @doc """
  Retrieves an event by its action and source identifiers with preloaded associations.

  This function looks up an event using its action, source system identifier,
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
          Event.t() | nil
  def get_event_by(action, source, source_idempk, instance_id) do
    Event
    |> Repo.get_by(
      action: action,
      source: source,
      source_idempk: source_idempk,
      instance_id: instance_id
    )
    |> Repo.preload([:event_queue_item, :account, transactions: [entries: :account]])
  end

  @doc """
  Gets the transaction associated with a create transaction event.

  This function finds the original create transaction event corresponding to an update event
  and returns its associated transaction. Used primarily when processing update events
  to locate the original transaction to modify.

  ## Parameters

  * `event` - An Event struct containing source, source_idempk, and instance_id

  ## Returns

  * `{:ok, {Transaction.t(), Event.t()}}` - The transaction and create event if found and processed
  * Raises `UpdateEventError` if the create event doesn't exist or isn't processed

  """
  @spec get_create_transaction_event_transaction(Event.t()) ::
          {:ok, {Transaction.t(), Event.t()}}
          | {:error | :pending_error, String.t(), Event.t() | nil}
  def get_create_transaction_event_transaction(
        %{
          source: source,
          source_idempk: source_idempk,
          instance_id: id
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

  * `event` - An Event struct containing source, source_idempk, and instance_id

  ## Returns

  * `{:ok, {Account.t(), Event.t()}}` - The account and create event if found and processed
  * Raises `UpdateEventError` if the create event doesn't exist or isn't processed

  """
  @spec get_create_account_event_account(Event.t()) ::
          {:ok, {Account.t(), Event.t()}}
          | {:error | :pending_error, String.t(), Event.t() | nil}
  def get_create_account_event_account(
        %{
          source: source,
          source_idempk: source_idempk,
          instance_id: id
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
  * `event_or_step` - Either an Event struct or the name of a previous step in the Multi

  ## Returns

  * `Ecto.Multi.t()` - The updated Multi instance with the new step added

  """
  @spec build_get_create_transaction_event_transaction(Ecto.Multi.t(), atom(), Event.t() | atom()) ::
          Ecto.Multi.t()
  def build_get_create_transaction_event_transaction(multi, step, event_or_step) do
    multi
    |> Multi.run(step, fn _, changes ->
      event =
        cond do
          is_struct(event_or_step, Event) -> event_or_step
          is_atom(event_or_step) -> Map.fetch!(changes, event_or_step)
        end

      try do
        {:ok, {transaction, _}} = get_create_transaction_event_transaction(event)
        {:ok, transaction}
      rescue
        e in UpdateEventError ->
          {:ok, {:error, e}}
      end
    end)
  end

  @doc """
  Builds an Ecto.Multi step to get a create account event's account.

  This function adds a step to an Ecto.Multi that retrieves the account associated with
  the create event corresponding to an update event. Handles error cases by wrapping
  exceptions in the result tuple.

  ## Parameters

  * `multi` - The Ecto.Multi instance to add the step to
  * `step` - The atom representing the step name in the Multi
  * `event_or_step` - Either an Event struct or the name of a previous step in the Multi

  ## Returns

  * `Ecto.Multi.t()` - The updated Multi instance with the new step added

  """
  @spec build_get_create_account_event_account(Ecto.Multi.t(), atom(), Event.t() | atom()) ::
          Ecto.Multi.t()
  def build_get_create_account_event_account(
        multi,
        step,
        event_or_step
      ) do
    multi
    |> Multi.run(step, fn _, changes ->
      event = get_event(event_or_step, changes)

      try do
        {:ok, {account, _}} = get_create_account_event_account(event)
        {:ok, account}
      rescue
        e in UpdateEventError ->
          {:ok, {:error, e}}
      end
    end)
  end

  @spec get_event(Event.t() | atom(), map()) :: Event.t()
  defp get_event(event_or_step, changes) do
    cond do
      is_struct(event_or_step, Event) -> event_or_step
      is_atom(event_or_step) -> Map.fetch!(changes, event_or_step)
    end
  end
end
