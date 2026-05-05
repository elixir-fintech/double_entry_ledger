defmodule DoubleEntryLedger.Stores.TransactionStoreHelper do
  @moduledoc """
  Provides helper functions for building Ecto.Multi operations related to transactions
  in the double-entry ledger system.

  This module focuses on constructing changesets and multi-step operations for creating
  and updating transactions, ensuring that all necessary validations and business rules
  are applied.
  ## Key Functionality
  * **Transaction Creation**: Build Ecto.Multi operations for creating new transactions
  * **Transaction Updates**: Build Ecto.Multi operations for updating existing transactions
  * **Error Handling**: Manage potential errors such as `Ecto.StaleEntryError` during concurrent updates
  * **Status Transitions**: Handle transaction status changes with appropriate validations
  ## Usage Examples
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias DoubleEntryLedger.{Account, BalanceHistoryEntry, Entry, Transaction, Types}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()

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
    |> insert_balance_history_entries({step, :balance_history_entries}, step, repo)
  end

  @doc """
  Parallel build path that bypasses `cast_assoc(:entries)` and
  inserts entries via `Repo.insert_all/3`, updating accounts with
  explicit `lock_version`-checked UPDATEs.

  Behaviour-equivalent to `build_create/4` for the
  `:create_transaction` action: same validations (balanced per
  currency, ≥2 entries, accounts on same ledger), same
  optimistic-concurrency semantics (raises `Ecto.StaleEntryError` on
  `lock_version` mismatch — the OCC retry handler in
  `OCC.Processor.retry/5` matches it under step `:transaction`).

  Used by the `insert_all` config branch of
  `CreateTransactionCommand.build_transaction/4`. Only `:posted` and
  `:pending` statuses are supported here (the update path —
  `pending_to_*` transitions — still flows through `build_create/4`).
  """
  @spec build_create_insert_all(Multi.t(), atom(), map(), Ecto.Repo.t()) :: Multi.t()
  def build_create_insert_all(multi, step, %{} = transaction_map, repo \\ Repo) do
    multi
    |> Multi.run(step, fn _, _ ->
      try do
        do_create_insert_all(transaction_map, repo)
      rescue
        e in Ecto.StaleEntryError ->
          {:error, e}
      end
    end)
    |> insert_balance_history_entries({step, :balance_history_entries}, step, repo)
  end

  defp do_create_insert_all(
         %{entries: entries, instance_id: instance_id, status: status} = transaction_map,
         repo
       ) do
    account_ids = Enum.map(entries, & &1.account_id)

    accounts =
      repo.all(
        from(a in Account, prefix: ^@schema_prefix, where: a.id in ^account_ids)
      )

    accounts_by_id = Map.new(accounts, &{&1.id, &1})

    with :ok <- assert_min_entries(transaction_map, entries),
         :ok <- assert_accounts_on_ledger(transaction_map, accounts_by_id, entries, instance_id),
         :ok <- assert_balanced(transaction_map, entries),
         {:ok, account_updates} <- compute_account_updates(transaction_map, accounts_by_id, entries, status) do
      now = DateTime.utc_now()

      with {:ok, transaction} <-
             Transaction.parent_changeset(%Transaction{}, transaction_map) |> repo.insert() do
        entry_rows = insert_entries(transaction, entries, now, repo)
        update_accounts!(account_updates, accounts_by_id, now, repo)

        # Skip the round-trip preload: we already have the entries (we
        # built and inserted them) and the post-update account state
        # (we computed it). Build the Entry/Account structs locally so
        # the downstream BHE step gets `entry.account` populated
        # without two extra SELECTs per command.
        transaction_with_entries = attach_entries_locally(transaction, entry_rows, account_updates, accounts_by_id, now)

        {:ok, transaction_with_entries}
      end
    end
  end

  defp insert_entries(transaction, entries, now, repo) do
    rows =
      Enum.map(entries, fn entry ->
        %{
          id: Ecto.UUID.generate(),
          transaction_id: transaction.id,
          account_id: entry.account_id,
          type: entry.type,
          value: entry.value,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, _} = repo.insert_all(Entry, rows, prefix: @schema_prefix)
    rows
  end

  defp attach_entries_locally(transaction, entry_rows, account_updates, accounts_by_id, now) do
    updated_accounts =
      Map.new(account_updates, fn {id, update} ->
        base = Map.fetch!(accounts_by_id, id)

        updated = %{
          base
          | posted: update.posted,
            pending: update.pending,
            available: update.available,
            lock_version: update.lock_version,
            updated_at: now
        }

        {id, updated}
      end)

    entries =
      Enum.map(entry_rows, fn row ->
        account = Map.fetch!(updated_accounts, row.account_id)
        struct(Entry, Map.put(row, :account, account))
      end)

    %{transaction | entries: entries}
  end

  # Issues one UPDATE per unique account, scoped by lock_version. A
  # row-count mismatch is mapped to Ecto.StaleEntryError so that the
  # OCC retry handler catches it the same way as the legacy path.
  defp update_accounts!(account_updates, accounts_by_id, now, repo) do
    Enum.each(account_updates, fn {account_id, update} ->
      old_lv = update.lock_version - 1

      query =
        from(a in Account,
          prefix: ^@schema_prefix,
          where: a.id == ^account_id and a.lock_version == ^old_lv
        )

      {count, _} =
        repo.update_all(query,
          set: [
            posted: update.posted,
            pending: update.pending,
            available: update.available,
            lock_version: update.lock_version,
            updated_at: now
          ]
        )

      if count == 0 do
        account = Map.fetch!(accounts_by_id, account_id)
        raise Ecto.StaleEntryError, action: :update, changeset: Ecto.Changeset.change(account)
      end
    end)
  end

  defp compute_account_updates(transaction_map, accounts_by_id, entries, status) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case Map.fetch(accounts_by_id, entry.account_id) do
        {:ok, account} ->
          case Account.compute_balance_changes(account, entry, status) do
            {:ok, update} ->
              {:cont, {:ok, Map.put(acc, account.id, update)}}

            {:error, field, message} ->
              {:halt, {:error, validation_error_changeset(transaction_map, field, message)}}
          end

        :error ->
          {:halt,
           {:error,
            validation_error_changeset(transaction_map, :account_id, "account not found")}}
      end
    end)
  end

  defp assert_min_entries(_transaction_map, entries) when length(entries) >= 2, do: :ok

  defp assert_min_entries(transaction_map, _entries),
    do: {:error, validation_error_changeset(transaction_map, :entry_count, "must have at least 2 entries")}

  defp assert_accounts_on_ledger(transaction_map, accounts_by_id, entries, instance_id) do
    if Enum.all?(entries, fn %{account_id: id} ->
         case Map.fetch(accounts_by_id, id) do
           {:ok, %{instance_id: ^instance_id}} -> true
           _ -> false
         end
       end) do
      :ok
    else
      {:error,
       validation_error_changeset(transaction_map, :account_id, "accounts must be on same ledger")}
    end
  end

  defp assert_balanced(transaction_map, entries) do
    case Transaction.assert_balanced(entries) do
      :ok ->
        :ok

      {:error, :unbalanced} ->
        {:error,
         validation_error_changeset(transaction_map, :value, "must have equal debit and credit")}
    end
  end

  defp validation_error_changeset(transaction_map, field, message) do
    %Transaction{}
    |> Transaction.parent_changeset(transaction_map)
    |> Ecto.Changeset.add_error(field, message)
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
        |> Repo.preload([entries: :account], force: true)

      transition = update_transition(transaction, attrs)

      try do
        Transaction.changeset(transaction, attrs, transition)
        |> repo.update()
      rescue
        e in Ecto.StaleEntryError ->
          {:error, e}
      end
    end)
    |> insert_balance_history_entries({step, :balance_history_entries}, step, repo)
  end

  # Inserts one BalanceHistoryEntry per entry on the transaction at `tx_step`.
  # Reads the post-write `Account` struct from `entry.account` (populated by
  # `put_account_assoc/2` during the cascading insert/update). Bypasses
  # `cast_assoc`/`put_assoc` to use a single batched `Repo.insert_all/3`.
  @spec insert_balance_history_entries(Multi.t(), term(), atom(), Ecto.Repo.t()) :: Multi.t()
  defp insert_balance_history_entries(multi, bhe_step, tx_step, repo) do
    Multi.run(multi, bhe_step, fn _repo, changes ->
      transaction = Map.fetch!(changes, tx_step)
      now = DateTime.utc_now()

      bhe_attrs =
        Enum.map(transaction.entries, fn entry ->
          BalanceHistoryEntry.build_from_account(entry.account, entry, now)
        end)

      {count, _} = repo.insert_all(BalanceHistoryEntry, bhe_attrs, prefix: @schema_prefix)

      {:ok, count}
    end)
  end

  @spec update_transition(Transaction.t(), map()) :: Types.trx_types()
  defp update_transition(%{status: :pending}, %{status: :posted}), do: :pending_to_posted
  defp update_transition(%{status: :pending}, %{status: :archived}), do: :pending_to_archived
  defp update_transition(%{status: :pending}, %{}), do: :pending_to_pending
end
