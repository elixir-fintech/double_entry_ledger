defmodule DoubleEntryLedger.TransactionStore do
  @moduledoc """
  This module defines the TransactionStore behaviour.
  """
  alias Ecto.Multi

  alias DoubleEntryLedger.{
    Repo,
    Transaction,
    Types
  }

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
  Creates a new transaction with the given attributes. This can throw an
  `Ecto.StaleEntryError` if the accounts associated with this transaction have
  been updated in the meantime. Generally it is recommended to use an event
  to create a transaction as this creates the full audit trail.

  ## Parameters

    - `transaction` - A map or `Transaction` struct containing the transaction data.

  ## Returns

    - `{:ok, %Transaction{}}` on success.
    - `{:error, changeset}` on failure.
  """
  @spec create(Transaction.t() | map()) :: {:ok, Transaction.t()} | {:error, any()}
  def create(transaction) do
    %Transaction{}
    |> Transaction.changeset(transaction)
    |> Repo.insert()
  end

  @doc """
  Updates an existing transaction with the given attributes. This can throw an
  `Ecto.StaleEntryError` if the accounts associated with this transaction have
  been updated in the meantime. Generally it is recommended to use an event
  to update a transaction as this creates the full audit trail.

  ## Parameters

    - `transaction` - The `Transaction` struct to be updated.
    - `attrs` - A map of attributes for the update.

  ## Returns

    - `{:ok, %Transaction{}}` on success.
    - `{:error, changeset}` on failure.
  """
  @spec update(Transaction.t(), map()) :: {:ok, Transaction.t()} | {:error, any()}
  def update(transaction, attrs) do
    transition = update_transition(transaction, attrs)

    transaction
    |> Transaction.changeset(attrs, transition)
    |> Repo.update()
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
  @spec build_update(Multi.t(), atom(), Transaction.t(), map(), Ecto.Repo.t()) :: Multi.t()
  def build_update(multi, step, transaction, attrs, repo \\ Repo) do
    transition = update_transition(transaction, attrs)

    multi
    |> Multi.run(step, fn _, _ ->
      try do
        Transaction.changeset(transaction, attrs, transition)
        |> repo.update()
      rescue
        e in Ecto.StaleEntryError ->
          {:error, e}
      end
    end)
  end

  @spec build_update2(Multi.t(), atom(), atom(), map(), Ecto.Repo.t()) :: Multi.t()
  def build_update2(multi, step, transaction_step, attrs, repo \\ Repo) do

    multi
    |> Multi.run(step, fn _, results ->
      transaction = Map.fetch!(results, transaction_step)
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
