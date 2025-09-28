defmodule DoubleEntryLedger.AccountStore do
  @moduledoc """
  Provides functions for managing and querying accounts in the double-entry ledger system.

  This module serves as the primary interface for all account-related operations, including
  creating, retrieving, updating, and deleting accounts. It also provides specialized
  query functions to retrieve accounts by various criteria and access account balance history.

  ## Key Functionality

  * **Account Management**: Create, retrieve, update, and delete accounts with full validation
  * **Account Queries**: Find accounts by instance, type, address, and ID combinations
  * **Balance History**: Access the historical record of account balance changes with pagination
  * **Event Sourcing**: Create and update account operations are tracked through the event sourcing system

  ## Data Integrity

  All account operations maintain strict data integrity through:
  * Event sourcing for complete audit trails
  * Validation of account types and currencies
  * Unique address constraints within instances
  * Referential integrity with instances and transactions

  ## Usage Examples

  Creating a new account:

      {:ok, instance} = DoubleEntryLedger.Stores.InstanceStore.create(%{address: "Business:Ledger"})
      {:ok, account} = DoubleEntryLedger.AccountStore.create(%{
        name: "Cash Account",
        address: "cash:main",
        instance_address: instance.address,
        currency: :USD,
        type: :asset
      })

  Retrieving accounts for an instance:

      {:ok, accounts} = DoubleEntryLedger.AccountStore.get_all_accounts_by_instance_address(instance.address)

  Accessing an account's balance history:

      {:ok, history} = DoubleEntryLedger.AccountStore.get_balance_history(account.id)

  ## Implementation Notes

  All functions perform appropriate validation and return standardized results:

  * Success: `{:ok, result}`
  * Error: `{:error, reason}` where reason can be an atom, string, or Ecto.Changeset

  The module integrates with the ledger's event sourcing system to ensure account integrity
  and enforce business rules for the double-entry accounting system. All create and update
  operations generate corresponding events for complete auditability.

  ## Error Handling

  Common error conditions include:
  * `:no_accounts_found` - When querying returns no results
  * `:some_accounts_not_found` - When some requested accounts don't exist
  * `Ecto.Changeset.t()` - For validation errors during create/update operations
  * String messages - For specific error conditions like "Account not found"
  """

  import Ecto.Query, only: [from: 2]

  import DoubleEntryLedger.Utils.Pagination, only: [paginate: 3]

  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.Apis.EventApi

  alias DoubleEntryLedger.{
    Repo,
    Currency,
    Account,
    Types,
    BalanceHistoryEntry,
    EventStore,
    Entry
  }

  @type create_map() :: %{
          instance_address: String.t(),
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
          instance_address: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          context: map() | nil
        }

  @doc """
  Retrieves an account by its ID.

  Loads the account with its associated events for complete context. Returns nil
  if the account doesn't exist.

  ## Parameters

    - `id` (Ecto.UUID.t()): The unique ID of the account to retrieve.

  ## Returns

    - `Account.t() | nil`: The account struct with preloaded events, or `nil` if not found.

  ## Preloaded Associations

    - `:events` - All events associated with this account for audit trail access

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
      iex> retrieved = AccountStore.get_by_id(account.id)
      iex> retrieved.id == account.id
      true

  """
  @spec get_by_id(Ecto.UUID.t()) :: Account.t() | nil
  def get_by_id(id) do
    Repo.get(Account, id, preload: [:events])
  end

  @doc """
  Retrieves an account by its address within a specific instance.

  Instance address is required to ensure uniqueness of account addresses across
  different instances in a multi-tenant system. Returns the account with preloaded
  events for complete context.

  ## Parameters

    - `instance_address` (String.t()): The unique address of the instance.
    - `account_address` (String.t()): The unique address of the account within the instance.

  ## Returns

    - `Account.t() | nil`: The account struct with preloaded events, or `nil` if not found.

  ## Preloaded Associations

    - `:events` - All events associated with this account

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
      iex> retrieved = AccountStore.get_by_address(instance_address, account.address)
      iex> retrieved.id
      account.id

  """
  @spec get_by_address(String.t(), String.t()) :: Account.t() | nil
  def get_by_address(instance_address, account_address) do
    from(a in Account,
      join: i in assoc(a, :instance),
      where: a.address == ^account_address and i.address == ^instance_address,
      preload: [:events]
    )
    |> Repo.one()
  end

  @doc """
  Creates a new account with the given attributes.

  Creates an account through the event sourcing system, ensuring proper audit trail
  and validation. The account is associated with the specified instance and must
  have a unique address within that instance.

  ## Parameters

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

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", instance_address: address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
      iex> account.address
      "account:main1"
      iex> {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.AccountEventMap{}, errors: errors}} = AccountStore.create(attrs, "unique_id_123")
      iex> {idempotent_error, _} = Keyword.get(errors, :source_idempk)
      iex> idempotent_error
      "already exists for this instance"

  """
  @spec create(create_map(), String.t(), String.t()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t(AccountEventMap.t()) | String.t()}
  def create(
        %{instance_address: address} = attrs,
        idempotent_id,
        source \\ "AccountStore.create/2"
      ) do
    response =
      EventApi.process_from_event_params_no_save_on_error(%{
        "instance_address" => address,
        "action" => "create_account",
        "source" => source,
        "source_idempk" => idempotent_id,
        "payload" => Map.delete(attrs, :instance_address)
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

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", description: "Test Description", instance_address: address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, updated_account} = AccountStore.update(account.address, %{instance_address: address, description: "Updated Description"}, "unique_update_id_456")
      iex> updated_account.description
      "Updated Description"

  """
  @spec update(String.t(), update_map(), String.t(), String.t()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t(AccountEventMap.t()) | String.t()}
  def update(
        address,
        %{instance_address: instance_address} = attrs,
        update_idempotent_id \\ Ecto.UUID.generate(),
        update_source \\ "AccountStore.update/2"
      ) do
    account = get_by_address(instance_address, address)
    event = EventStore.get_create_account_event(account.id)

    response =
      EventApi.process_from_event_params_no_save_on_error(%{
        "instance_address" => instance_address,
        "action" => "update_account",
        "source" => event.source,
        "source_idempk" => event.source_idempk,
        "update_idempk" => update_idempotent_id,
        "update_source" => update_source,
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

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
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
  Retrieves an account's balance history by its ID with pagination support.

  Returns a paginated list of balance history entries showing how the account's
  balance has changed over time. Each entry includes the associated transaction
  ID for complete traceability.

  ## Parameters

    - `id` (Ecto.UUID.t()): The unique ID of the account.
    - `page` (non_neg_integer(), optional): The page number for pagination (default: 1).
    - `per_page` (non_neg_integer(), optional): The number of entries per page (default: 40).

  ## Returns

    - `{:ok, list(BalanceHistoryEntry)}`: A list of balance history entries on success.
    - `{:error, message}`: If the account is not found.

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, balance_history} = AccountStore.get_balance_history_by_id(account.id)
      iex> is_list(balance_history)
      true

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{id: instance_id}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:error, :account_not_found} = AccountStore.get_balance_history_by_id(instance_id)

  """
  @spec get_balance_history_by_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, list(BalanceHistoryEntry.t())} | {:error, :account_not_found}
  def get_balance_history_by_id(id, page \\ 1, per_page \\ 40) do
    case get_by_id(id) do
      nil -> {:error, :account_not_found}
      account -> get_balance_history_by_account(account, page, per_page)
    end
  end

  @doc """
  Retrieves an account's balance history by its address within a specific instance, with pagination support.

  Returns a paginated list of balance history entries showing how the account's
  balance has changed over time. Each entry includes the associated transaction
  ID for complete traceability.

  ## Parameters

    - `instance_address` (String.t()): The address of the instance.
    - `account_address` (String.t()): The address of the account within the instance.
    - `page` (non_neg_integer(), optional): The page number for pagination (default: 1).
    - `per_page` (non_neg_integer(), optional): The number of entries per page (default: 40).

  ## Returns

    - `{:ok, list(BalanceHistoryEntry)}`: A list of balance history entries on success.
    - `{:error, message}`: If the account is not found.

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, balance_history} = AccountStore.get_balance_history_by_address(instance_address, account.address)
      iex> is_list(balance_history)
      true

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:error, :account_not_found} = AccountStore.get_balance_history_by_address(instance_address, "nonexistent_account")

  """
  @spec get_balance_history_by_address(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, list(BalanceHistoryEntry.t())} | {:error, :account_not_found}
  def get_balance_history_by_address(instance_address, account_address, page \\ 1, per_page \\ 40) do
    case get_by_address(instance_address, account_address) do
      nil -> {:error, :account_not_found}
      account -> get_balance_history_by_account(account, page, per_page)
    end
  end

  @spec get_balance_history_by_account(Account.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, list(BalanceHistoryEntry.t())}
  def get_balance_history_by_account(%Account{id: id}, page \\ 1, per_page \\ 40) do
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
         order_by: [desc: b.inserted_at]
       )
       |> paginate(page, per_page)
     )}
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

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address, id: instance_id}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account1} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, account2} = AccountStore.create(%{attrs | address: "account:main2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3"}, "unique_id_789")
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
      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, account1} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, account2} = AccountStore.create(%{attrs | address: "account:main2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3"}, "unique_id_789")
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

  @doc """
  Retrieves accounts by instance ID and account type.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the instance.
    - `type` (Types.account_type()): The type of the accounts.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If no accounts of the specified type were found.

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address, id: instance_id}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, _} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main2", name: "Account 2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3", name: "Account 3", type: :liability}, "unique_id_789")
      iex> {:ok, accounts} = AccountStore.get_accounts_by_instance_id_and_type(instance_id, :asset)
      iex> length(accounts)
      2

  """
  @spec get_accounts_by_instance_id_and_type(Ecto.UUID.t(), Types.account_type()) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found_for_provided_type}
  def get_accounts_by_instance_id_and_type(instance_id, type) do
    from(a in Account,
      where: a.instance_id == ^instance_id and a.type == ^type
    )
    |> handle_accounts_by_instance_id_queries(0)
  end

  @doc """
  Retrieves all accounts by instance ID.

  ## Parameters

    - `instance_address` (String.t()): The address of the instance.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If no accounts were found.

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, %{address: instance_address2}} = InstanceStore.create(%{address: "Sample:Instance2"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, _} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main2", name: "Account 2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3", name: "Account 3"}, "unique_id_789")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3", name: "Account 3", instance_address: instance_address2}, "unique_id_101")
      iex> {:ok, accounts} = AccountStore.get_all_accounts_by_instance_address(instance_address)
      iex> length(accounts)
      3

  """
  @spec get_all_accounts_by_instance_address(String.t()) ::
          {:ok, list(Account.t())} | {:error, :no_accounts_found}
  def get_all_accounts_by_instance_address(instance_address) do
    from(a in Account,
      join: i in assoc(a, :instance),
      where: i.address == ^instance_address,
      select: a
    )
    |> handle_accounts_by_instance_id_queries(0)
  end

  @doc """
  Retrieves all accounts by instance ID.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the instance.

  ## Returns

    - `{:ok, accounts}`: On success.
    - `{:error, message}`: If no accounts were found.

  ## Examples

      iex> alias DoubleEntryLedger.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, %{id: instance_id, address: instance_address}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, %{address: instance_address2}} = InstanceStore.create(%{address: "Sample:Instance2"})
      iex> attrs = %{name: "Test Account", address: "account:main1", instance_address: instance_address, currency: :EUR, type: :asset}
      iex> {:ok, _} = AccountStore.create(attrs, "unique_id_123")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main2", name: "Account 2"}, "unique_id_456")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3", name: "Account 3"}, "unique_id_789")
      iex> {:ok, _} = AccountStore.create(%{attrs | address: "account:main3", name: "Account 3", instance_address: instance_address2}, "unique_id_101")
      iex> {:ok, accounts} = AccountStore.get_all_accounts_by_instance_id(instance_id)
      iex> length(accounts)
      3

  """
  @spec get_all_accounts_by_instance_id(Ecto.UUID.t()) ::
          {:ok, list(Account.t())} | {:error, :no_accounts_found}
  def get_all_accounts_by_instance_id(instance_id) do
    from(a in Account,
      where: a.instance_id == ^instance_id
    )
    |> handle_accounts_by_instance_id_queries(0)
  end

  @spec handle_accounts_by_instance_id_queries(Ecto.Query.t(), non_neg_integer()) ::
          {:ok, list(Account.t())}
          | {:error, :no_accounts_found | :some_accounts_not_found}
  defp handle_accounts_by_instance_id_queries(query, 0) do
    case get_accounts(query) do
      [] -> {:error, :no_accounts_found}
      accounts -> {:ok, accounts}
    end
  end

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
