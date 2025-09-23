defmodule DoubleEntryLedger.AccountStore do
  @moduledoc """
  Provides functions for managing and querying accounts in the double-entry ledger system.

  This module serves as the primary interface for all account-related operations, including
  creating, retrieving, updating, and deleting accounts. It also provides specialized
  query functions to retrieve accounts by various criteria and access account balance history.

  ## Key Functionality

  * **Account Management**: Create, retrieve, update, and delete accounts
  * **Account Queries**: Find accounts by instance, type, and ID combinations
  * **Balance History**: Access the historical record of account balance changes

  ## Usage Examples

  Creating a new account:

      {:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{name: "Business Ledger"})
      {:ok, account} = DoubleEntryLedger.AccountStore.create(%{
        name: "Cash",
        instance_id: instance.id,
        currency: :USD,
        type: :asset
      })

  Retrieving accounts for an instance:

      {:ok, accounts} = DoubleEntryLedger.AccountStore.get_all_accounts_by_instance_id(instance.id)

  Accessing an account's balance history:

      {:ok, history} = DoubleEntryLedger.AccountStore.get_balance_history(account.id)

  ## Implementation Notes

  All functions perform appropriate validation and return standardized results:

  * Success: `{:ok, result}`
  * Error: `{:error, reason}`

  The module integrates with the ledger's validation system to ensure account integrity
  and enforce business rules for the double-entry accounting system.
  """
  import Ecto.Query, only: [from: 2]

  import DoubleEntryLedger.AccountStoreHelper,
    only: [get_by_address_and_instance: 2]

  alias DoubleEntryLedger.{
    Repo,
    Account,
    Types,
    BalanceHistoryEntry,
    EventStore,
    Entry,
    InstanceStore
  }

  @doc """
  Retrieves an account by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account.

  ## Returns

    - `account`: The account struct, or `nil` if not found.

  ## Examples

      iex> {:ok, %{address: instance_address}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> retrieved = DoubleEntryLedger.AccountStore.get_by_id(account.id)
      iex> retrieved.id == account.id
      true

  """
  @spec get_by_id(Ecto.UUID.t()) :: Account.t() | nil
  def get_by_id(id) do
    Repo.get(Account, id, preload: [:events])
  end

  @doc """
  Creates a new account with the given attributes.

  ## Parameters

    - `attrs` (map): A map of attributes for the account.

  ## Returns

    - `{:ok, account}`: On success.
    - `{:error, changeset}`: If there was an error during creation.

  ## Examples

      iex> {:ok, %{address: address}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: address, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> account.name
      "Test Account"

  """
  @spec create(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def create(%{instance_address: address} = attrs, source \\ "AccountStore.create/1") do
    response = EventStore.process_from_event_params_no_save_on_error(
      %{
        "instance_address" => address,
        "action" => "create_account",
        "source" => source,
        "source_idempk" => Ecto.UUID.generate(),
        "payload" => Map.delete(attrs, :instance_address)
      }
    )
    case response do
      {:ok, account, _event} -> {:ok, account}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates an account with the given attributes, only allowing changes to the description and the context.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account to update.
    - `attrs` (map): The attributes to update.

  ## Returns

    - `{:ok, account}`: On success.
    - `{:error, changeset}`: If there was an error during update.

  ## Examples

      iex> {:ok, %{address: address}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", description: "Test Description", instance_address: address, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, updated_account} = DoubleEntryLedger.AccountStore.update(account.address, %{instance_address: address, description: "Updated Description"})
      iex> updated_account.description
      "Updated Description"

  """
  @spec update(Ecto.UUID.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update(address, %{instance_address: instance_address} = attrs, source \\ "AccountStore.update/2") do
    instance = InstanceStore.get_by_address(instance_address)
    account = get_by_address_and_instance(address, instance.id)
    event = EventStore.get_create_account_event(account.id)

    response = EventStore.process_from_event_params_no_save_on_error(
      %{
        "instance_address" => instance_address,
        "action" => "update_account",
        "source" => event.source,
        "source_idempk" => event.source_idempk,
        "update_idempk" => Ecto.UUID.generate(),
        "update_source" => source,
        "payload" => Map.delete(attrs, :instance_address)
      }
    )
    case response do
      {:ok, account, _event} -> {:ok, account}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Deletes an account by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the account to delete.

  ## Returns

    - `{:ok, account}`: On success.
    - `{:error, changeset}`: If there was an error during deletion.

  ## Examples

      iex> {:ok, %{address: instance_address}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
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

      iex> {:ok, %{address: instance_address}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, balance_history} = DoubleEntryLedger.AccountStore.get_balance_history(account.id)
      iex> is_list(balance_history)
      true

      iex> {:ok, %{id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
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

      iex> {:ok, %{address: instance_address, id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account1} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, account2} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main2"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main3"})
      iex> {:ok, accounts} = DoubleEntryLedger.AccountStore.get_accounts_by_instance_id(instance_id, [account1.address, account2.address])
      iex> length(accounts)
      2

  """
  @spec get_accounts_by_instance_id(Ecto.UUID.t(), list(String.t())) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found | :some_accounts_not_found | :no_account_ids_provided}
  def get_accounts_by_instance_id(_instance_id, []), do: {:error, :no_account_ids_provided}

  def get_accounts_by_instance_id(instance_id, account_addresses) do
    accounts =
      Repo.all(
        from(a in Account,
          where: a.instance_id == ^instance_id and a.address in ^account_addresses
        )
      )

    cond do
      accounts == [] ->
        {:error, :no_accounts_found}

      length(accounts) < length(account_addresses) ->
        {:error, :some_accounts_not_found}

      true ->
        {:ok, accounts}
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

      iex> {:ok, %{address: instance_address, id: instance_id}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main2", name: "Account 2"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main3", name: "Account 3", type: :liability})
      iex> {:ok, accounts} = DoubleEntryLedger.AccountStore.get_accounts_by_instance_id_and_type(instance_id, :asset)
      iex> length(accounts)
      2

  """
  @spec get_accounts_by_instance_id_and_type(Ecto.UUID.t(), Types.account_type()) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found_for_provided_type}
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
      {:error, :no_accounts_found_for_provided_type}
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

      iex> {:ok, %{id: instance_id, address: instance_address}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, %{address: instance_address2}} = DoubleEntryLedger.InstanceStore.create(%{address: "Sample:Instance2"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(attrs)
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main2", name: "Account 2"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main3", name: "Account 3"})
      iex> {:ok, _} = DoubleEntryLedger.AccountStore.create(%{attrs | address: "account:main3", name: "Account 3", instance_address: instance_address2})
      iex> {:ok, accounts} = DoubleEntryLedger.AccountStore.get_all_accounts_by_instance_id(instance_id)
      iex> length(accounts)
      3

  """
  @spec get_all_accounts_by_instance_id(Ecto.UUID.t()) ::
          {:ok, list(Account.t())} | {:error, :no_accounts_found}
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
      {:error, :no_accounts_found}
    end
  end
end
