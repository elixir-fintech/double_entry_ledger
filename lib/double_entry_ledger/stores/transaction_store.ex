defmodule DoubleEntryLedger.TransactionStore do
  @moduledoc """
  This module defines the TransactionStore behaviour.
  """
  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Transaction, Account}

  @doc """
  Creates a new transaction with the given attributes.

  ## Parameters

    - transaction: The attributes of the transaction to be created.

  ## Returns

      - An `Ecto.Multi` struct representing the database operations to be performed.

  """
  @spec create(Transaction.t() | map()) :: Ecto.Multi.t()
  def create(transaction) do
    Multi.new()
    |> Multi.insert(:transaction, Transaction.changeset(%Transaction{}, transaction))
    |> Multi.run(:entries, fn repo, %{transaction: t} ->
         {:ok, repo.preload(t, [entries: :account], [{:force, true}])}
      end)
    |> Multi.merge(fn %{entries: %{entries: entries}} ->
         Enum.reduce(entries, Multi.new(), fn %{account: account} = entry, multi ->
           multi
           |> Multi.update(
                account.id,
                Account.update_balances(account, %{entry: entry, trx: transaction.status})
              )
         end)
      end)
    |> Repo.transaction()
  end

  @doc """
  Updates a transaction with the given attributes.

  ## Parameters

    - transaction: The `Transaction` struct to be updated.
    - attrs: A map of attributes to update the transaction with.

  ## Returns

    - An `Ecto.Multi` struct representing the database operations to be performed.


  """
  @spec update(Transaction.t(), map()) :: Ecto.Multi.t()
  def update(%{status: now } = transaction, %{status: next } = attr) do
    transition = case {now, next } do
      {:pending, :posted } -> :pending_to_posted
      {:pending, :archived } -> :pending_to_archived
      {_, _ } -> now
    end

    Multi.new()
    |> Multi.update(:transaction, Transaction.changeset(transaction, attr))
    |> Multi.run(:entries, fn repo, %{transaction: t} ->
         {:ok, repo.preload(t, [entries: :account], [{:force, true}])}
      end)
    |> Multi.merge(fn %{entries: %{entries: entries}} ->
         Enum.reduce(entries, Multi.new(), fn %{account: account} = entry, multi ->
           multi
           |> Multi.update(
                account.id,
                Account.update_balances(account, %{entry: entry, trx: transition})
              )
         end)
      end)
    |> Repo.transaction()
  end
end
