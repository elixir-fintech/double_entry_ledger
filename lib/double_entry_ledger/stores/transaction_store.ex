defmodule DoubleEntryLedger.TransactionStore do
  @moduledoc """
  Provides functions for managing transactions in the double-entry ledger system.

  ## Key Functionality

  * **Complex Queries**: Find transactions by instance ID and account relationships
  * **Multi Integration**: Build operations that integrate with Ecto.Multi for atomic operations
  * **Optimistic Concurrency**: Handle Ecto.StaleEntryError with appropriate error handling
  * **Status Transitions**: Manage transaction state transitions with validation

  ## Usage Examples

  Retrieving a transaction by ID:

      transaction = DoubleEntryLedger.TransactionStore.get_by_id(transaction_id)

  Getting transactions for an instance:

      transactions = DoubleEntryLedger.TransactionStore.list_all_for_instance(instance.id)

  Getting transactions for an account in an instance:

      transactions = DoubleEntryLedger.TransactionStore.list_all_for_instance_and_account(instance.id, account.id)

  ## Implementation Notes

  There are no create/update functions, as there is no audit trail for these operations. Instead use an event to create or update a transaction.
  It uses optimistic concurrency control to handle concurrent modifications to related accounts.
  """
  alias Ecto.Multi
  import Ecto.Query

  alias DoubleEntryLedger.{
    Account,
    Entry,
    Repo,
    Transaction,
    Types,
    BalanceHistoryEntry
  }

  @doc """
  Retrieves a transaction by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the transaction.

  ## Returns

    - `transaction`: The transaction struct, or `nil` if not found.
  """
  @spec get_by_id(Ecto.UUID.t(), list()) :: Transaction.t() | nil
  def get_by_id(id, preload \\ []) do
    transaction = Repo.get(Transaction, id)

    if transaction != nil and preload != [] do
      Repo.preload(transaction, preload)
    else
      transaction
    end
  end

  @doc """
  Lists all transactions for a given instance.
  The output is paginated.

  ## Parameters

    - `instance_id` - The UUID of the instance.
    - `page` - The page number (defaults to 1).
    - `per_page` - The number of transactions per page (defaults to 40).

  ## Returns

    - A list of transactions.
  """
  @spec list_all_for_instance(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Transaction.t())
  def list_all_for_instance(instance_id, page \\ 1, per_page \\ 40) do
    offset = (page - 1) * per_page

    Repo.all(
      from(t in Transaction,
        where: t.instance_id == ^instance_id,
        order_by: [desc: t.inserted_at],
        limit: ^per_page,
        offset: ^offset,
        select: t
      )
    )
  end

  @doc """
  Lists all transactions for a given instance and account. This function joins the transactions
  with their associated entries, accounts, and the latest balance history entry for each entry.
  The output is paginated.

  ## Parameters

    - `instance_id` - The UUID of the instance.
    - `account_id` - The UUID of the account
    - `page` - The page number (defaults to 1).
    - `per_page` - The number of transactions per page (defaults to 40).

  ## Returns

    - A list of tuples containing the transaction, account, entry, and the latest balance history entry.
  """
  @spec list_all_for_instance_and_account(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          list({Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()})
  def list_all_for_instance_and_account(instance_id, account_id, page \\ 1, per_page \\ 40) do
    offset = (page - 1) * per_page

    Repo.all(
      from(transaction in Transaction,
        join: entry in assoc(transaction, :entries),
        on: entry.transaction_id == transaction.id,
        as: :entry,
        join: account in assoc(entry, :account),
        on: account.id == entry.account_id,
        left_lateral_join:
          latest_balance_history in subquery(
            from(balance_history in BalanceHistoryEntry,
              where: balance_history.entry_id == parent_as(:entry).id,
              order_by: [desc: balance_history.inserted_at],
              limit: 1,
              select: balance_history
            )
          ),
        on: latest_balance_history.entry_id == entry.id,
        order_by: [desc: transaction.inserted_at],
        limit: ^per_page,
        offset: ^offset,
        where: entry.account_id == ^account_id and transaction.instance_id == ^instance_id,
        select: {transaction, account, entry, latest_balance_history}
      )
    )
  end

  @doc """
  Builds an `Ecto.Multi` to create a new transaction. This is used as a building block for more complex
  operations.

  It also handles the `Ecto.StaleEntryError` exception that can be raised when accounts associated
  with the transaction have been updated in the meantime. In this case it returns an error tuple
  which is then converted to an Ecto.Multi.failure() to be handled by the caller.

  ## Parameters

    - `multi` - The existing `Ecto.Multi` struct.
    - `step` - An atom representing the name of the operation.
    - `transaction` - A map of transaction attributes.
    - `repo` - The repository module (defaults to `Repo`).

  ## Returns

    - An `Ecto.Multi` struct with the create operation added.
  """
  @spec build_create(Multi.t(), atom(), map(), Ecto.Repo.t()) :: Multi.t()
  # Dialyzer requires a map here
  def build_create(multi, step, %{} = transaction, repo \\ Repo) do
    multi
    |> Multi.run(step, fn _, _ ->
      try do
        Transaction.changeset(%Transaction{}, transaction)
        |> repo.insert()
      rescue
        e in Ecto.StaleEntryError ->
          {:error, e}
      end
    end)
  end

  @doc """
  Builds an `Ecto.Multi` to update a transaction. This is used as a building block for more complex
  operations.

  It also handles the `Ecto.StaleEntryError` exception that can be raised when accounts associated
  with the transaction have been updated in the meantime. In this case it returns an error tuple
  which is then converted to an Ecto.Multi.failure() to be handled by the caller.

  ## Parameters

    - `multi` - The existing `Ecto.Multi` struct.
    - `step` - An atom representing the name of the operation.
    - `transaction` - The `Transaction` struct to be updated.
    - `attrs` - A map of attributes for the update.
    - `repo` - The repository module (defaults to `Repo`).

  ## Returns

    - An `Ecto.Multi` struct with the update operation added.
  """
  @spec build_update(Multi.t(), atom(), Transaction.t() | atom(), map(), Ecto.Repo.t()) ::
          Multi.t()
  def build_update(multi, step, transaction_or_step, attrs, repo \\ Repo) do
    multi
    |> Multi.run(step, fn _, changes ->
      transaction =
        cond do
          is_struct(transaction_or_step, Transaction) -> transaction_or_step
          is_atom(transaction_or_step) -> Map.fetch!(changes, transaction_or_step)
        end

      transition = update_transition(transaction, attrs)

      try do
        Transaction.changeset(transaction, attrs, transition)
        |> repo.update()
      rescue
        e in Ecto.StaleEntryError ->
          {:error, e}
      end
    end)
  end

  @spec update_transition(Transaction.t(), map()) :: Types.trx_types()
  defp update_transition(%{status: :pending}, %{status: :posted}), do: :pending_to_posted
  defp update_transition(%{status: :pending}, %{status: :archived}), do: :pending_to_archived
  defp update_transition(%{status: :pending}, %{}), do: :pending_to_pending
end
