defmodule DoubleEntryLedger.Stores.JournalEventStoreHelper do
  @moduledoc """
  Helper functions for journal event queries in the Double Entry Ledger system.

  This module provides reusable utilities for working with journal events, focusing on common
  operations like retrieving related journal events by source identifiers, finding transactions
  and accounts associated with journal events, and building queries for audit trail access.

  ## Key Functionality

  * **Journal Event Lookup**: Find journal events by action and source identifiers
  * **Command Relationships**: Look up related journal events for commands
  * **Transaction Linking**: Find transactions and accounts associated with journal events
  * **Query Building**: Compose queries for journal events by account or transaction

  ## Implementation Notes

  This module is primarily used internally by JournalEventStore and CommandWorker modules to
  share common functionality and reduce code duplication.
  """
  import Ecto.Query, only: [from: 2, subquery: 1, union: 2]

  alias DoubleEntryLedger.{Command, JournalEvent, Account, Entry}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError

  @doc """
  Retrieves a journal event by its action and source identifiers with preloaded associations.

  This function looks up a journal event using its action, source system identifier,
  source-specific identifier, and instance ID. The returned journal event includes a
  preloaded account association.

  ## Parameters

    - `action`: The command action atom (e.g., `:create_transaction`, `:create_account`)
    - `source`: The source system identifier (e.g., "accounting_system", "api")
    - `source_idempk`: The source-specific identifier (e.g., "invoice_123", "tx_456")
    - `instance_id`: The instance UUID that scopes the lookup

  ## Returns

    - `JournalEvent.t() | nil`: The found journal event with preloaded account, or nil if not found

  """
  @spec get_event_by(atom(), String.t(), String.t(), Ecto.UUID.t()) ::
          JournalEvent.t() | nil
  def get_event_by(action, source, source_idempk, instance_id) do
    from(e in JournalEvent,
      where:
        e.instance_id == ^instance_id and
          fragment("command_map->>? = ?", "action", ^Atom.to_string(action)) and
          fragment("command_map->>? = ?", "source", ^source) and
          fragment("command_map->>? = ?", "source_idempk", ^source_idempk),
      limit: 1,
      preload: [:account]
    )
    |> Repo.one()
  end

  @doc """
  Gets the account associated with a create account command's journal event.

  This function finds the original create account journal event corresponding to an update
  command and returns its associated account. Used primarily when processing account update
  commands to locate the original account to modify.

  ## Parameters

  * `command` - A Command struct containing source, source_idempk, and instance_id

  ## Returns

  * `{:ok, {Account.t(), JournalEvent.t()}}` - The account and create journal event if found
  * Raises `UpdateCommandError` if the create journal event doesn't exist or isn't processed

  """
  @spec get_create_account_event_account(Command.t()) ::
          {:ok, {Account.t(), JournalEvent.t()}}
          | {:error | :pending_error, String.t(), JournalEvent.t() | nil}
  def get_create_account_event_account(
        %{
          instance_id: id,
          command_map: %{
            source: source,
            source_idempk: source_idempk
          }
        } = event
      ) do
    case get_event_by(:create_account, source, source_idempk, id) do
      %{account: account} = create_account_event ->
        {:ok, {account, create_account_event}}

      create_account_event ->
        raise UpdateCommandError,
          create_command: create_account_event,
          update_command: event
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
      join: a in assoc(je, :account),
      where: a.id == ^account_id,
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
      join: t in assoc(je, :transaction),
      where: t.id == ^transaction_id,
      select: je,
      preload: [transaction: :entries]
    )
  end
end
