defmodule DoubleEntryLedger.TransactionStoreHelper do
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

  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Transaction, Types}

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
