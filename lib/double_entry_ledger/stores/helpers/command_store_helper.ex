defmodule DoubleEntryLedger.Stores.CommandStoreHelper do
  @moduledoc """
  Helper functions for event processing in the Double Entry Ledger system.

  This module provides reusable utilities for working with events, focusing on common
  operations like building changesets, retrieving related events and transactions, and
  creating multi operations for use in Ecto transactions.

  ## Key Functionality

  * **Changeset Building**: Create Command changesets from TransactionCommandMaps or AccountCommandMaps
  * **Command Relationships**: Look up related events by source identifiers
  * **Transaction Linking**: Find transactions and accounts associated with events
  * **Ecto.Multi Integration**: Build multi operations for atomic database transactions
  * **Status Management**: Create changesets to update event status and error information

  ## Usage Examples

  Building a changeset from an CommandMap:

      event_changeset = CommandStoreHelper.build_create(command_map)

  Adding a step to get a create event's transaction:

      multi =
        Ecto.Multi.new()
        |> CommandStoreHelper.build_get_create_transaction_command_transaction(:transaction, update_command)
        |> Ecto.Multi.update(:event, fn %{transaction: transaction} ->
          CommandStoreHelper.build_mark_as_processed(update_command, transaction.id)
        end)

  ## Implementation Notes

  This module is primarily used internally by CommandStore and CommandWorker modules to
  share common functionality and reduce code duplication.
  """
  import Ecto.Query, only: [from: 2]

  alias DoubleEntryLedger.Command.{TransactionCommandMap, AccountCommandMap}
  alias Ecto.Changeset
  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Command, Transaction, Account, Entry, PendingTransactionLookup}
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError

  @doc """
  Builds an Command changeset from a TransactionCommandMap or AccountCommandMap.

  Creates a new Command changeset suitable for database insertion, converting the
  provided event map structure into the appropriate Command attributes.

  ## Parameters

  * `command_map` - Either a TransactionCommandMap or AccountCommandMap struct containing event data

  ## Returns

  * `Ecto.Changeset.t(Command.t())` - A changeset for creating a new Command

  """
  @spec build_create(TransactionCommandMap.t() | AccountCommandMap.t(), Ecto.UUID.t()) ::
          Changeset.t(Command.t())
  def build_create(%TransactionCommandMap{} = command_map, instance_id) do
    %Command{}
    |> Command.changeset(%{
      instance_id: instance_id,
      command_map: TransactionCommandMap.to_map(command_map)
    })
  end

  def build_create(%AccountCommandMap{} = command_map, instance_id) do
    %Command{}
    |> Command.changeset(%{instance_id: instance_id, command_map: AccountCommandMap.to_map(command_map)})
  end

  @doc """
  Retrieves an event by its action and source identifiers with preloaded associations.

  This function looks up an event using i
      command_map
      |> TransactionCommandMap.to_map()
      |> Map.put(:instance_id, instance_id)
      |> Mts action, source system identifier,
  source-specific identifier, and instance ID. The returned event includes preloaded
  associations for command_queue_item, account, and transactions with their entries.

  ## Parameters

    - `action`: The event action atom (e.g., `:create_transaction`, `:create_account`)
    - `source`: The source system identifier (e.g., "accounting_system", "api")
    - `source_idempk`: The source-specific identifier (e.g., "invoice_123", "tx_456")
    - `instance_id`: The instance UUID that groups related events

  ## Returns

    - `Command.t() | nil`: The found event with preloaded associations, or nil if not found

  ## Preloaded Associations

  The returned event includes:
  - `:command_queue_item` - Processing status and retry information
  - `:account` - Associated account (for account-related events)
  - `transactions: [entries: :account]` - Transactions with their entries and accounts

  """
  @spec get_command_by(atom(), String.t(), String.t(), Ecto.UUID.t()) ::
          Command.t() | nil
  def get_command_by(action, source, source_idempk, instance_id) do
    from(e in Command,
      where:
        e.instance_id == ^instance_id and
          fragment("command_map->>? = ?", "action", ^Atom.to_string(action)) and
          fragment("command_map->>? = ?", "source", ^source) and
          fragment("command_map->>? = ?", "source_idempk", ^source_idempk),
      limit: 1,
      preload: [:command_queue_item, transaction: [entries: :account]]
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
  * Raises `UpdateCommandError` if the create event doesn't exist or isn't processed

  """
  @spec get_create_transaction_command_transaction(Command.t()) ::
          {:ok, {Transaction.t(), Command.t()}}
          | {:error | :pending_error, String.t(), Command.t() | nil}
  def get_create_transaction_command_transaction(command) do
    case pending_transaction_lookup(command) do
      %{transaction: transaction, command: create_command} when not is_nil(transaction) ->
        {:ok, {transaction, create_command}}

      %{command: create_command} when not is_nil(create_command) ->
        raise UpdateCommandError,
          create_event: create_command,
          update_command: command

      _ ->
        raise UpdateCommandError,
          create_event: nil,
          update_command: command
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
  @spec build_get_create_transaction_command_transaction(
          Ecto.Multi.t(),
          atom(),
          Command.t() | atom()
        ) ::
          Ecto.Multi.t()
  def build_get_create_transaction_command_transaction(multi, step, command_or_step) do
    multi
    |> Multi.run(step, fn _, changes ->
      event = get_command(command_or_step, changes)

      try do
        {:ok, {transaction, _}} = get_create_transaction_command_transaction(event)
        {:ok, transaction}
      rescue
        e in UpdateCommandError ->
          {:ok, {:error, e}}
      end
    end)
  end

  @spec pending_transaction_lookup(Command.t()) :: PendingTransactionLookup.t()
  defp pending_transaction_lookup(%{
         instance_id: iid,
         command_map: %{source: s, source_idempk: sidpk}
       }) do
    from(ptl in PendingTransactionLookup,
      where: ptl.instance_id == ^iid and ptl.source == ^s and ptl.source_idempk == ^sidpk,
      limit: 1,
      preload: [command: :command_queue_item, transaction: [entries: :account]]
    )
    |> Repo.one()
  end

  @spec base_transaction_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def base_transaction_query(transaction_id) do
    from(c in Command,
      join: t in assoc(c, :transaction),
      where: t.id == ^transaction_id,
      preload: [:command_queue_item, transaction: :entries]
    )
  end

  @spec base_account_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def base_account_query(account_id) do
    from(c in Command,
      join: a in assoc(c, :account),
      where: a.id == ^account_id,
      select: c
    )
  end

  @spec transaction_events_for_account_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def transaction_events_for_account_query(account_id) do
    from(c in Command,
      join: t in assoc(c, :transaction),
      join: ety in Entry,
      on: ety.transaction_id == t.id,
      join: a in Account,
      on: a.id == ety.account_id,
      where: a.id == ^account_id,
      select: c
    )
  end

  @spec get_command(Command.t() | atom(), map()) :: Command.t()
  defp get_command(command_or_step, changes) do
    cond do
      is_struct(command_or_step, Command) -> command_or_step
      is_atom(command_or_step) -> Map.fetch!(changes, command_or_step)
    end
  end
end
