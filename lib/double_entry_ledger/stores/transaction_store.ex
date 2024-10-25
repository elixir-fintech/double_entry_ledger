defmodule DoubleEntryLedger.TransactionStore do
  @moduledoc """
  This module defines the TransactionStore behaviour.
  """
  alias Ecto.Multi
  alias DoubleEntryLedger.{
    Repo, Transaction, Account, Types
  }

  @doc """
  Builds an Ecto.Multi() struct to create a new transaction with the given attributes.

  ## Parameters

    - transaction: The attributes of the transaction to be created.

  ## Returns

      - An `Ecto.Multi` struct representing the database operations to be performed.
  """
  @spec build_create(map()) :: Multi.t()
  def build_create(%{} = transaction) do # Dialyzer requires a map here
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
      end
    )
  end

  @doc """
  Creates a new transaction with the given attributes.

  ## Parameters
    - transaction: The attributes of the transaction to be created.

  ## Returns
    - {:ok, Transaction.t()} | {:error, Ecto.Changeset.t()}
  """
  @spec create(Transaction.t() | map()) :: {:ok, Transaction.t()} | {:error, any()}
  def create(transaction) do
    case build_create(transaction) |> Repo.transaction() do
      {:ok, %{transaction: transaction}} -> {:ok, transaction}
      {:error, _name , failed_step, _changes_so_far} -> {:error, failed_step}
    end
  end

  @doc """
  Builds an Ecto.Multi() to update a transaction with the given attributes.

  ## Parameters
    - transaction: The `Transaction` struct to be updated.
    - attrs: A map of attributes to update the transaction with.

  ## Returns
    - An `Ecto.Multi` struct representing the database operations to be performed.
  """
  @spec build_update(Transaction.t(), map()) :: Multi.t()
  def build_update(%{status: :pending } = trx, %{status: :posted } = attr) do
    base_build_update(trx, attr, :pending_to_posted)
  end

  def build_update(%{status: :pending } = trx, %{status: :archived } = attr) do
    base_build_update(trx, attr, :pending_to_archived)
  end

  def build_update(%{status: :pending } = trx, attr) do
    base_build_update(trx, attr, :pending)
  end

  @doc """
  Updates a transaction with the given attributes.

  ## Parameters
    - transaction: The `Transaction` struct to be updated.
    - attrs: A map of attributes to update the transaction with.

  ## Returns
      - {:ok, Transaction.t()} | {:error, any()}
  """
  @spec update(Transaction.t(), map()) :: {:ok, Transaction.t()} | {:error, any()}
  def update(transaction, attrs) do
    case build_update(transaction, attrs) |> Repo.transaction() do
      {:ok, %{transaction: transaction}} -> {:ok, transaction}
      {:error, _name , failed_step, _changes_so_far} -> {:error, failed_step}
    end
  end

  @spec base_build_update(Transaction.t(), map(), Types.trx_types()) :: Ecto.Multi.t()
  defp base_build_update(transaction, attr, transition) do
    changeset = Transaction.changeset(transaction, attr, transition)
    Multi.new()
    |> Multi.update(:transaction, changeset)
  end
end
