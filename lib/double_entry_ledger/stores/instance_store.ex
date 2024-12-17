defmodule DoubleEntryLedger.InstanceStore do
  @moduledoc """
  Provides functions to interact with ledger instances.

  This module includes functions for creating, retrieving, updating, and deleting ledger instances.
  It respects the constraints and validations defined in `DoubleEntryLedger.Instance`.
  """
  alias DoubleEntryLedger.{Instance, Repo}

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
end
