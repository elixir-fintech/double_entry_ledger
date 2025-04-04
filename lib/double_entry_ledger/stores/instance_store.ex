defmodule DoubleEntryLedger.InstanceStore do
  @moduledoc """
  Provides functions to interact with ledger instances.

  This module includes functions for creating, retrieving, updating, and deleting ledger instances.
  It respects the constraints and validations defined in `DoubleEntryLedger.Instance`.
  """
  import Ecto.Query, only: [from: 2]
  alias DoubleEntryLedger.{Instance, Repo, Account}

  @doc """
  Creates a new ledger instance with the given attributes.

  ## Parameters

    - `attrs` (map): A map of attributes for the ledger instance.

  ## Returns

    - `{:ok, instance}`: On success.
    - `{:error, changeset}`: If there was an error during creation.

  ## Examples

      iex> attrs = %{name: "Test Ledger"}
      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(attrs)
      iex> instance.name
      "Test Ledger"

  """
  @spec create(map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Instance{}
    |> Instance.changeset(attrs)
    |> Repo.insert()
  end

  def list_all do
    Repo.all(Instance)
  end

  @doc """
  Retrieves a ledger instance by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the ledger instance.

  ## Returns

    - `instance`: The ledger instance struct, or `nil` if not found.

  ## Examples

      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Ledger"})
      iex> retrieved = DoubleEntryLedger.InstanceStore.get_by_id(instance.id)
      iex> retrieved.id == instance.id
      true

  """
  @spec get_by_id(Ecto.UUID.t()) :: Instance.t() | nil
  def get_by_id(id) do
    Repo.get(Instance, id)
  end

  @doc """
  Updates a ledger instance with the given attributes.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the ledger instance to update.
    - `attrs` (map): The attributes to update.

  ## Returns

    - `{:ok, instance}`: On success.
    - `{:error, changeset}`: If there was an error during update.

  ## Examples

      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{name: "Ledger"})
      iex> {:ok, updated_instance} = DoubleEntryLedger.InstanceStore.update(instance.id, %{name: "Updated Ledger"})
      iex> updated_instance.name
      "Updated Ledger"

  """
  @spec update(Ecto.UUID.t(), map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def update(id, attrs) do
    get_by_id(id)
    |> Instance.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a ledger instance by its ID.

  Ensures that there are no associated transactions or accounts before deletion, as defined in `Instance.delete_changeset/1`.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the ledger instance to delete.

  ## Returns

    - `{:ok, instance}`: On success.
    - `{:error, changeset}`: If there was an error during deletion.

  ## Examples

      iex> {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{name: "Temporary Ledger"})
      iex> {:ok, _} = DoubleEntryLedger.InstanceStore.delete(instance.id)
      iex> DoubleEntryLedger.InstanceStore.get_by_id(instance.id) == nil
      true

  """
  @spec delete(Ecto.UUID.t()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def delete(id) do
    get_by_id(id)
    |> Instance.delete_changeset()
    |> Repo.delete()
  end

  @doc """
  Calculates the sum of debits and credits for all accounts in a ledger instance, grouped by currency.

  This function runs a database query in a transaction with REPEATABLE READ isolation level to ensure
  consistent results even if accounts are being updated concurrently.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the ledger instance.

  ## Returns

    - `{:ok, list(map)}`: On success, returns a list of maps containing currency, posted_debit,
      posted_credit, pending_debit, and pending_credit sums.
    - `{:error, reason}`: If there was an error during the transaction.

  """
  @spec sum_accounts_debits_and_credits_by_currency(Ecto.UUID.t()) ::
          {:ok, list(map())} | {:error, Ecto.Changeset.t()}
  def sum_accounts_debits_and_credits_by_currency(instance_id) do
    Repo.transaction(
      fn ->
        query =
          from(a in Account,
            where: a.instance_id == ^instance_id,
            group_by: a.currency,
            select: %{
              currency: a.currency,
              posted_debit: type(sum(fragment("(posted->>'debit')::integer")), :integer),
              posted_credit: type(sum(fragment("(posted->>'credit')::integer")), :integer),
              pending_debit: type(sum(fragment("(pending->>'debit')::integer")), :integer),
              pending_credit: type(sum(fragment("(pending->>'credit')::integer")), :integer)
            }
          )

        Repo.all(query)
      end,
      isolation: :repeatable_read
    )
  end
end
