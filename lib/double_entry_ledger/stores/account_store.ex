defmodule DoubleEntryLedger.Stores.AccountStore do
  @moduledoc """
  Provides functions for managing and querying accounts in the double-entry ledger system.

  This module serves as the primary interface for all account-related operations, including
  creating, retrieving, updating, and deleting accounts. It also provides specialized
  query functions to retrieve accounts by various criteria and access account balance history.

  ## Key Functionality

  * **Account Management**: Create, retrieve, update, and delete accounts with full validation
  * **Account Queries**: Find accounts by instance, type, address, and ID combinations
  * **Balance History**: Access the historical record of account balance changes with pagination
  * **Command Sourcing**: Create and update account operations are tracked through the command pipeline

  ## Data Integrity

  All account operations maintain strict data integrity through:
  * Command sourcing for complete audit trails
  * Validation of account types and currencies
  * Unique address constraints within instances
  * Referential integrity with instances and transactions

  ## Usage Examples

  Creating a new account:

      {:ok, instance} = DoubleEntryLedger.Stores.InstanceStore.create(%{address: "Business:Ledger"})
      {:ok, account} = DoubleEntryLedger.Stores.AccountStore.create(%{
        name: "Cash Account",
        address: "cash:main",
        instance_address: instance.address,
        currency: :USD,
        type: :asset
      })

  Retrieving accounts for an instance:

      {:ok, {accounts, _meta}} = DoubleEntryLedger.Stores.AccountStore.list_for_instance_address(instance.address)

  Accessing an account's balance history:

      {:ok, {history, _meta}} = DoubleEntryLedger.Stores.AccountStore.list_balance_history(account)

  ## Implementation Notes

  All functions perform appropriate validation and return standardized results:

  * Success: `{:ok, result}`
  * Error: `{:error, reason}` where reason can be an atom, string, or Ecto.Changeset

  The module integrates with the ledger's command pipeline to ensure account integrity
  and enforce business rules for the double-entry accounting system. All create and update
  operations generate corresponding commands for complete auditability.

  ## Error Handling

  Common error conditions include:
  * `:no_accounts_found` - When querying returns no results
  * `:some_accounts_not_found` - When some requested accounts don't exist
  * `Ecto.Changeset.t()` - For validation errors during create/update operations
  * String messages - For specific error conditions like "Account not found"
  """

  import Ecto.Query, only: [from: 2]

  alias DoubleEntryLedger.Command.AccountCommandMap
  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.Utils.Currency
  alias DoubleEntryLedger.Stores.AccountStoreHelper

  alias DoubleEntryLedger.{
    Repo,
    Account,
    Instance,
    Types,
    BalanceHistoryEntry
  }

  @type create_map() :: %{
          address: String.t(),
          currency: Currency.currency_atom(),
          type: Types.account_type(),
          name: String.t() | nil,
          description: String.t() | nil,
          context: map() | nil,
          normal_balance: Types.credit_or_debit() | nil,
          allow_negative: boolean() | nil
        }

  @type update_map() :: %{
          name: String.t() | nil,
          description: String.t() | nil,
          context: map() | nil
        }

  @doc """
  Retrieves an account by its ID.

  Returns the account struct or nil if the account doesn't exist.
  No associations are preloaded; use `get_by_address/2` for preloaded journal events.

  ## Parameters

    - `id` (Ecto.UUID.t()): The unique ID of the account to retrieve.

  ## Returns

    - `Account.t() | nil`: The account struct, or `nil` if not found.

  ## Examples

      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(instance_address, attrs, "unique_id_123")
      iex> retrieved = AccountStore.get_by_id(account.id)
      iex> retrieved.id == account.id
      true

  """
  @spec get_by_id(Ecto.UUID.t()) :: Account.t() | nil
  def get_by_id(id) do
    Repo.get(Account, id)
  end

  @doc """
  Retrieves an account by its address within a specific instance.

  Instance address is required to ensure uniqueness of account addresses across
  different instances in a multi-tenant system. Returns the account with preloaded
  journal events for complete context.

  ## Parameters

    - `instance_address` (String.t()): The unique address of the instance.
    - `account_address` (String.t()): The unique address of the account within the instance.

  ## Returns

    - `Account.t() | nil`: The account struct with preloaded journal events, or `nil` if not found.

  ## Preloaded Associations

    - `:journal_events` - All journal events associated with this account

  ## Examples

      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(instance_address, attrs, "unique_id_123")
      iex> retrieved = AccountStore.get_by_address(instance_address, account.address)
      iex> retrieved.id
      account.id

  """
  @spec get_by_address(String.t(), String.t()) :: Account.t() | nil
  def get_by_address(instance_address, account_address) do
    AccountStoreHelper.get_by_address_query(instance_address, account_address)
    |> Repo.one()
  end

  @doc """
  Creates a new account with the given attributes.

  Creates an account through the command pipeline, ensuring proper audit trail
  and validation. The account is associated with the specified instance and must
  have a unique address within that instance.

  ## Parameters

    - `instance_address` (String.t()): Address of the instance
    - `attrs` (map): A map of attributes for the account containing:
      - `:name` (String.t(), optional) - Human-readable account name
      - `:address` (String.t(), required) - Unique address within the instance
      - `:instance_address` (String.t(), required) - Address of the owning instance
      - `:currency` (atom, required) - Currency code (e.g., :USD, :EUR)
      - `:type` (atom, required) - Account type (:asset, :liability, :equity, :income, :expense)
      - `:description` (String.t(), optional) - Account description
      - `:context` (map, optional) - Additional context information
      - `:normal_balance` (atom, optional) - Normal balance (:debit or :credit) if different from type default
      - `:allow_negative` (boolean, optional) - Whether negative balances are allowed (default: false)

    - `source` (String.t(), optional): Source identifier for the operation (defaults to "AccountStore.create/1")

  ## Returns

    - `{:ok, Account.t()}`: On successful creation with the created account.
    - `{:error, Ecto.Changeset.t() | String.t()}`: If validation fails or other errors occur.

  ## Validation Rules

    - Account address must be unique within the instance
    - Account type must be one of the valid types
    - Currency must be a valid currency code
    - Instance must exist

  ## Examples

      iex> {:ok, %{address: address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(address, attrs)
      iex> account.address
      "account:main1"

  """
  @spec create(String.t(), create_map(), String.t()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t(AccountCommandMap.t()) | String.t()}
  def create(
        instance_address,
        attrs,
        source \\ "account_store-create"
      ) do
    response =
      CommandApi.process_from_params(%{
        "instance_address" => instance_address,
        "action" => "create_account",
        "source" => source,
        "payload" => attrs
      })

    case response do
      {:ok, account, _event} -> {:ok, account}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates an account with the given attributes.

  Updates an existing account through the event sourcing system. Only allows changes
  to specific fields (description and context) to maintain data integrity. The update
  creates a new event linking to the original creation event.

  ## Parameters

    - `instance_address` (String.t()): Address of the instance
    - `address` (String.t()): The address of the account to update within the instance.
    - `attrs` (map): The attributes to update containing:
      - `:instance_address` (String.t., required) - Address of the owning instance
      - `:name` (String.t., optional) - Updated account name
      - `:description` (String.t., optional) - Updated description
      - `:context` (map, optional) - Updated context information
    - `source` (String.t., optional): Update source identifier for the operation (defaults to "AccountStore.update/2")

  ## Returns

    - `{:ok, Account.t()}`: On successful update with the updated account.
    - `{:error, Ecto.Changeset.t()}`: If validation fails or the account doesn't exist.

  ## Updateable Fields
    - `name` - Account display name
    - `description` - Account description text
    - `context` - Additional contextual information

  ## Immutable Fields

  The following fields cannot be changed after creation:
    - `name`, `address`, `type`, `currency`, `instance_id`

  ## Examples

      iex> {:ok, %{address: address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", description: "Test Description", currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(address, attrs)
      iex> {:ok, updated_account} = AccountStore.update(address, account.address, %{instance_address: address, description: "Updated Description"})
      iex> updated_account.description
      "Updated Description"

  """
  @spec update(String.t(), String.t(), update_map(), String.t()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t(AccountCommandMap.t()) | String.t()}
  def update(
        instance_address,
        account_address,
        attrs,
        source \\ "account_store-update"
      ) do
    account = get_by_address(instance_address, account_address)

    response =
      CommandApi.process_from_params(%{
        "instance_address" => instance_address,
        "account_address" => account.address,
        "action" => "update_account",
        "source" => source,
        "payload" => Map.delete(attrs, :instance_address)
      })

    case response do
      {:ok, account, _event} -> {:ok, account}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Deletes an account by its ID. This only works if the account has no associated transactions which means it can be safely removed from the ledger.
  Should only be used if the account was created in error and has no transactions.
  Deletion will currently not show up in the event log.

  ## Parameters

    - `id` (Ecto.UUID.t()): The unique ID of the account to delete.

  ## Returns

    - `{:ok, Account.t()}`: On successful deletion with the deleted account struct.
    - `{:error, Ecto.Changeset.t()}`: If the account cannot be deleted (e.g., has active transactions).

  ## Constraints

    - Accounts with existing transactions cannot be deleted

  ## Examples

      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(instance_address, attrs, "unique_id_123")
      iex> {:ok, _} = AccountStore.delete(account.id)
      iex> AccountStore.get_by_id(account.id) == nil
      true

  """
  @spec delete(Ecto.UUID.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def delete(id) do
    get_by_id(id)
    |> Account.delete_changeset()
    |> Repo.delete()
  end

  @doc """
  Lists accounts for a ledger instance with cursor pagination.

  Accepts either an `%Instance{}` struct or its UUID string.

  ## Parameters

    - `instance_or_id` (`Instance.t() | Ecto.UUID.t()`): Parent instance or its id.
    - `flop_params` (map, optional): Flop params. Filterable fields: `:type`, `:currency`, `:address`.

  ## Returns

    - `{:ok, {[Account.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.

  ## Examples

      iex> {:ok, %{address: instance_address} = instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, _} = AccountStore.create(instance_address, attrs, "unique_id_123")
      iex> {:ok, {[account], %Flop.Meta{}}} = AccountStore.list_for_instance(instance)
      iex> account.address
      "account:main1"

  """
  @spec list_for_instance(Instance.t() | Ecto.UUID.t(), map()) ::
          {:ok, {[Account.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_instance(instance_or_id, flop_params \\ %{})

  def list_for_instance(%Instance{id: id}, flop_params), do: list_for_instance(id, flop_params)

  def list_for_instance(id, flop_params) when is_binary(id) do
    from(a in Account, where: a.instance_id == ^id)
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: Account)
  end

  @doc """
  Lists accounts for the instance with the given human-readable address.

  Returns an empty first page when the instance address does not exist, so callers
  don't need to branch on existence separately from the pagination meta.
  """
  @spec list_for_instance_address(String.t(), map()) ::
          {:ok, {[Account.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_instance_address(instance_address, flop_params \\ %{}) do
    from(a in Account,
      join: i in assoc(a, :instance),
      where: i.address == ^instance_address
    )
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: Account)
  end

  @doc """
  Lists an account's balance history with cursor pagination.

  Accepts either an `%Account{}` struct or its UUID string.
  """
  @spec list_balance_history(Account.t() | Ecto.UUID.t(), map()) ::
          {:ok, {[BalanceHistoryEntry.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_balance_history(account_or_id, flop_params \\ %{})

  def list_balance_history(%Account{id: id}, flop_params),
    do: list_balance_history(id, flop_params)

  def list_balance_history(id, flop_params) when is_binary(id) do
    from(b in BalanceHistoryEntry, where: b.account_id == ^id)
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: BalanceHistoryEntry)
  end

  @doc """
  Lists an account's balance history by instance+account address with cursor pagination.

  Returns an empty first page when the (instance_address, account_address) pair does
  not resolve to an existing account.
  """
  @spec list_balance_history_by_address(String.t(), String.t(), map()) ::
          {:ok, {[BalanceHistoryEntry.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_balance_history_by_address(instance_address, account_address, flop_params \\ %{}) do
    from(b in BalanceHistoryEntry,
      join: a in assoc(b, :account),
      join: i in assoc(a, :instance),
      where: i.address == ^instance_address and a.address == ^account_address
    )
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: BalanceHistoryEntry)
  end

  @doc """
  Retrieves accounts by instance ID and a list of account addresses.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the instance.
    - `account_addresses` (list(String.t())): The list of account addresses.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If some accounts were not found.

  ## Examples

      iex> {:ok, %{address: instance_address, id: instance_id}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, account1} = AccountStore.create(instance_address, attrs, "unique_id_123")
      iex> {:ok, account2} = AccountStore.create(instance_address, %{attrs | address: "account:main2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(instance_address, %{attrs | address: "account:main3"}, "unique_id_789")
      iex> {:ok, accounts} = AccountStore.get_accounts_by_instance_id(instance_id, [account1.address, account2.address])
      iex> length(accounts)
      2

  """
  @spec get_accounts_by_instance_id(Ecto.UUID.t(), list(String.t())) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found | :some_accounts_not_found | :no_accounts_provided}
  def get_accounts_by_instance_id(_instance_id, []), do: {:error, :no_accounts_provided}

  def get_accounts_by_instance_id(instance_id, account_addresses) do
    from(a in Account,
      where: a.instance_id == ^instance_id and a.address in ^account_addresses
    )
    |> handle_accounts_by_instance_id_queries(length(account_addresses))
  end

  @doc """
  Get a list of accounts by instance address and a list of account addresses.

  ## Parameters

    - `instance_address` (String.t()): The address of the instance.
    - `account_addresses` (list(String.t())): The list of account addresses.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If some accounts were not found.

  ## Examples
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", currency: :EUR, type: :asset}
      iex> {:ok, account1} = AccountStore.create(instance_address, attrs, "unique_id_123")
      iex> {:ok, account2} = AccountStore.create(instance_address, %{attrs | address: "account:main2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(instance_address, %{attrs | address: "account:main3"}, "unique_id_789")
      iex> {:ok, accounts} = AccountStore.get_accounts_by_instance_address(instance_address, [account1.address, account2.address])
      iex> length(accounts)
      2
  """
  @spec get_accounts_by_instance_address(String.t(), list(String.t())) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found | :some_accounts_not_found}
  def get_accounts_by_instance_address(_instance_address, []),
    do: {:error, :no_accounts_provided}

  def get_accounts_by_instance_address(instance_address, account_addresses) do
    from(a in Account,
      join: i in assoc(a, :instance),
      where: i.address == ^instance_address and a.address in ^account_addresses,
      select: a
    )
    |> handle_accounts_by_instance_id_queries(length(account_addresses))
  end

  @spec handle_accounts_by_instance_id_queries(Ecto.Query.t(), non_neg_integer()) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found | :some_accounts_not_found}
  defp handle_accounts_by_instance_id_queries(query, input_length) do
    accounts = get_accounts(query)

    cond do
      accounts == [] ->
        {:error, :no_accounts_found}

      length(accounts) < input_length ->
        {:error, :some_accounts_not_found}

      true ->
        {:ok, accounts}
    end
  end

  defp get_accounts(query) do
    query
    |> Ecto.Query.order_by([a], asc: a.address)
    |> Repo.all()
  end
end
