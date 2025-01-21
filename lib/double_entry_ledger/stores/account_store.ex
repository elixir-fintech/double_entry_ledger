defmodule DoubleEntryLedger.AccountStore do
  @moduledoc """
  This module defines the AccountStore behaviour.
  """
  import Ecto.Query, only: [from: 2]
  alias DoubleEntryLedger.{Repo, Account, Types}

  @doc """
  Creates a new account with the given attributes.

  ## Parameters

    - `attrs` (map): A map of attributes for the account.

  ## Returns

    - `{:ok, account}`: On success.
    - `{:error, changeset}`: If there was an error during creation.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> account.name
      "Test Account"

  """
  @spec create(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieves an account by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account.

  ## Returns

    - `account`: The account struct, or `nil` if not found.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> retrieved = DoubleEntryLedger.AccountStore.get_by_id(account.id)
      iex> retrieved.id == account.id
      true

  """
  @spec get_by_id(Ecto.UUID.t()) :: Account.t() | nil
  def get_by_id(id) do
    Repo.get(Account, id)
  end

  @doc """
  Updates an account with the given attributes.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account to update.
    - `attrs` (map): The attributes to update.

  ## Returns

    - `{:ok, account}`: On success.
    - `{:error, changeset}`: If there was an error during update.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, updated_account} = DoubleEntryLedger.AccountStore.update(account.id, %{name: "Updated Account"})
      iex> updated_account.name
      "Updated Account"

  """
  @spec update(Ecto.UUID.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update(id, attrs) do
    get_by_id(id)
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Retrieves accounts by instance ID and a list of account IDs.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the instance.
    - `account_ids` (list(String.t())): The list of account IDs.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If some accounts were not found.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, account1} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, account2} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 2"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 3"})
      iex> {:ok, accounts} = DoubleEntryLedger.AccountStore.get_accounts_by_instance_id(instance_id, [account1.id, account2.id])
      iex> length(accounts)
      2

  """
  @spec get_accounts_by_instance_id(Ecto.UUID.t(), list(String.t())) :: {:error, String.t()} | {:ok, list(Account.t())}
  def get_accounts_by_instance_id(instance_id, account_ids) do
    accounts = Repo.all(
      from a in Account,
      where: a.instance_id == ^instance_id and a.id in ^account_ids
    )
    if length(accounts) == length(account_ids) do
      {:ok, accounts}
    else
      {:error, "Some accounts were not found"}
    end
  end

  @doc """
  Retrieves accounts by instance ID and account type.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the instance.
    - `type` (Types.account_type()): The type of the accounts.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If no accounts of the specified type were found.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 2"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 3", type: :liability})
      iex> {:ok, accounts} = DoubleEntryLedger.AccountStore.get_accounts_by_instance_id_and_type(instance_id, :asset)
      iex> length(accounts)
      2

  """
  @spec get_accounts_by_instance_id_and_type(Ecto.UUID.t(), Types.account_type()) :: {:error, String.t()} | {:ok, list(Account.t())}
  def get_accounts_by_instance_id_and_type(instance_id, type) do
    accounts = Repo.all(
      from a in Account,
      where: a.instance_id == ^instance_id and a.type == ^type
    )
    if length(accounts) > 0 do
      {:ok, accounts}
    else
      {:error, "No #{type} accounts were found"}
    end
  end

  @doc """
  Retrieves all accounts by instance ID.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the instance.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If no accounts were found.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> {:ok, %{id: instance_id2}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 2"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 3"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | name: "Account 3", instance_id: instance_id2})
      iex> {:ok, accounts} = DoubleEntryLedger.AccountStore.get_all_accounts_by_instance_id(instance_id)
      iex> length(accounts)
      3

  """
  @spec get_all_accounts_by_instance_id(Ecto.UUID.t()) :: {:error, String.t()} | {:ok, list(Account.t())}
  def get_all_accounts_by_instance_id(instance_id) do
    accounts = Repo.all(from a in Account, where: a.instance_id == ^instance_id)
    if length(accounts) > 0 do
      {:ok, accounts}
    else
      {:error, "No accounts were found"}
    end
  end
end
