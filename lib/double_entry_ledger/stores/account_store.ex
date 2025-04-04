defmodule DoubleEntryLedger.AccountStore do
  @moduledoc """
  This module defines the AccountStore behaviour.
  """
  import Ecto.Query, only: [from: 2]

  alias DoubleEntryLedger.{
    Repo,
    Account,
    Types,
    BalanceHistoryEntry,
    Entry
  }

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
    |> Account.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an account by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account to delete.

  ## Returns

    - `{:ok, account}`: On success.
    - `{:error, changeset}`: If there was an error during deletion.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.delete(account.id)
      iex> DoubleEntryLedger.AccountStore.get_by_id(account.id) == nil
      true

  """
  @spec delete(Ecto.UUID.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def delete(id) do
    get_by_id(id)
    |> Account.delete_changeset()
    |> Repo.delete()
  end

  @doc """
  Retrieves an account's balance_history by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account.
    - `page` (non_neg_integer()): The page number for pagination (default: 1).
    - `per_page` (non_neg_integer()): The number of entries per page (default: 40).

  ## Returns

    - `{:ok, list(BalanceHistoryEntry)}`: A list of balance history entries on success.
    - `{:error, message}`: If the account is not found.

  ## Examples

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> attrs = %{name: "Test Account", instance_id: instance_id, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, balance_history} = DoubleEntryLedger.AccountStore.get_balance_history(account.id)
      iex> is_list(balance_history)
      true

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{name: "Sample Instance"})
      iex> {:error, _} = DoubleEntryLedger.AccountStore.get_balance_history(instance_id)

  """
  @spec get_balance_history(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, list(BalanceHistoryEntry.t())} | {:error, String.t()}
  def get_balance_history(id, page \\ 1, per_page \\ 40) do
    offset = (page - 1) * per_page

    case get_by_id(id) do
      nil ->
        {:error, "Account not found"}

      _ ->
        {:ok,
         Repo.all(
           from(b in BalanceHistoryEntry,
             where: b.account_id == ^id,
             left_join: e in Entry,
             on: b.entry_id == e.id,
             select:
               merge(
                 map(b, [
                   :id,
                   :account_id,
                   :entry_id,
                   :available,
                   :posted,
                   :pending,
                   :inserted_at,
                   :updated_at
                 ]),
                 %{transaction_id: e.transaction_id}
               ),
             order_by: [desc: b.inserted_at],
             limit: ^per_page,
             offset: ^offset
           )
         )}
    end
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
  @spec get_accounts_by_instance_id(Ecto.UUID.t(), list(String.t())) ::
          {:error, String.t()} | {:ok, list(Account.t())}
  def get_accounts_by_instance_id(instance_id, account_ids) do
    accounts =
      Repo.all(
        from(a in Account,
          where: a.instance_id == ^instance_id and a.id in ^account_ids
        )
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
  @spec get_accounts_by_instance_id_and_type(Ecto.UUID.t(), Types.account_type()) ::
          {:error, String.t()} | {:ok, list(Account.t())}
  def get_accounts_by_instance_id_and_type(instance_id, type) do
    accounts =
      Repo.all(
        from(a in Account,
          where: a.instance_id == ^instance_id and a.type == ^type
        )
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
  @spec get_all_accounts_by_instance_id(Ecto.UUID.t()) ::
          {:error, String.t()} | {:ok, list(Account.t())}
  def get_all_accounts_by_instance_id(instance_id) do
    accounts =
      Repo.all(
        from(a in Account,
          where: a.instance_id == ^instance_id,
          order_by: [asc: a.name]
        )
      )

    if length(accounts) > 0 do
      {:ok, accounts}
    else
      {:error, "No accounts were found"}
    end
  end
end
