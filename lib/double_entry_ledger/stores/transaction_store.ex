defmodule DoubleEntryLedger.Stores.TransactionStore do
  @moduledoc """
  Provides functions for managing transactions in the double-entry ledger system.

  ## Key Functionality

  * **Complex Queries**: Find transactions by instance ID and account relationships
  * **Multi Integration**: Build operations that integrate with Ecto.Multi for atomic operations
  * **Optimistic Concurrency**: Handle Ecto.StaleEntryError with appropriate error handling
  * **Status Transitions**: Manage transaction state transitions with validation

  ## Usage Examples

  Retrieving a transaction by ID:

      transaction = DoubleEntryLedger.Stores.TransactionStore.get_by_id(transaction_id)

  Getting transactions for an instance:

      transactions = DoubleEntryLedger.Stores.TransactionStore.list_all_for_instance(instance.id)

  Getting transactions for an account in an instance:

      transactions = DoubleEntryLedger.Stores.TransactionStore.list_all_for_instance_and_account(instance.id, account.id)

  ## Implementation Notes

  There are no create/update functions, as there is no audit trail for these operations. Instead use an event to create or update a transaction.
  It uses optimistic concurrency control to handle concurrent modifications to related accounts.
  """
  import Ecto.Query

  import DoubleEntryLedger.Utils.Pagination, only: [paginate: 3]

  alias DoubleEntryLedger.{
    Account,
    Currency,
    Entry,
    Repo,
    Transaction,
    BalanceHistoryEntry
  }

  alias DoubleEntryLedger.Stores.EventStore
  alias DoubleEntryLedger.Apis.EventApi
  alias DoubleEntryLedger.Event.TransactionEventMap

  @type entry_map() :: %{
          account_address: String.t(),
          amount: integer(),
          currency: Currency.currency_atom()
        }

  @type create_map() :: %{
          instance_address: String.t(),
          status: Transaction.state(),
          entries: list(entry_map())
        }

  @type update_map() :: %{
          instance_address: String.t(),
          status: Transaction.state(),
          entries: list(entry_map()) | nil
        }

  @doc """
  Creates a new transaction with the given attributes. If the creation fails, the event is saved
  to the event queue and retried later.

  ## Parameters

    - `attrs` (map): A map containing the transaction attributes.
      - `:instance_address` (String.t()): The address of the instance.
      - `:status` (Transaction.state()): The initial status of the transaction.
      - `:entries` (list(entry_map())): A list of entry maps, each containing:
        - `:account_address` (String.t()): The address of the account.
        - `:amount` (integer()): The amount for the entry.
        - `:currency` (Currency.currency_atom()): The currency for the entry.
    - `idempotent_id` (String.t()): A unique identifier to ensure idempotency of the creation request.
    - `opts` (Keyword.t(), optional): A string indicating the source of the creation request.
      - `:source` Defaults to `"TransactionStore.create/3"
      - `:retry_on_error` defaults to true. If true, event will be saved in the EventQueue for retry after a processing error. Otherwise Event is not stored at all.
  ## Returns

    - `{:ok, transaction}`: On successful creation, returns the created transaction.
    - `{:error, reason}`: On failure, returns an error tuple with the reason.

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.{InstanceStore, TransactionStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
      iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   instance_address: instance.address,
      ...>   status: :posted,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, transaction} = TransactionStore.create(create_attrs, "unique_id_123")
      iex> transaction.status
      :posted
      iex> {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.TransactionEventMap{}} = changeset} = TransactionStore.create(create_attrs , "unique_id_123")
      iex> {idempotent_error, _} = Keyword.get(changeset.errors, :source_idempk)
      iex> idempotent_error
      "already exists for this instance"

  """
  @spec create(create_map(), String.t(), Keyword.t()) ::
          {:ok, Transaction.t()}
          | {:error, Ecto.Changeset.t(TransactionEventMap.t()) | String.t()}
  def create(%{instance_address: address} = attrs, idempotent_id, opts \\ []) do
    source = Keyword.get(opts, :source, "TransactionStore.create/3")
    retry_on_error = Keyword.get(opts, :retry_on_error, true)

    params = %{
      "instance_address" => address,
      "action" => "create_transaction",
      "source" => source,
      "source_idempk" => idempotent_id,
      "payload" => Map.delete(attrs, :instance_address)
    }

    response =
      case retry_on_error do
        false -> EventApi.process_from_event_params_no_save_on_error(params)
        _ -> EventApi.process_from_event_params(params)
      end

    case response do
      {:ok, transaction, _event} -> {:ok, transaction}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates a transaction with the given attributes. If the update fails, the event is saved
  to the event queue and retried later.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the transaction to update.
    - `attrs` (map): A map containing the transaction attributes.
      - `:instance_address` (String.t()): The address of the instance.
      - `:status` (Transaction.state()): The new status of the transaction.
      - `:entries` (list(entry_map())): A list of entry maps, each containing:
        - `:account_address` (String.t()): The address of the account.
        - `:amount` (integer()): The amount for the entry.
        - `:currency` (Currency.currency_atom()): The currency for the entry.
    - `update_idempk` (String.t()): A unique identifier to ensure idempotency of the update request.
    - `opts` (Keyword.t(), optional): A string indicating the source of the creation request.
      - `:update_source` Defaults to `"TransactionStore.update/4", use if the source of the change is different from the initial source when creating the event
      - `:retry_on_error` defaults to true. If true, event will be saved in the EventQueue for retry after a processing error. Otherwise Event is not stored at all.

  ## Returns

    - `{:ok, transaction}`: On successful creation, returns the created transaction.
    - `{:error, reason}`: On failure, returns an error tuple with the reason.

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.{InstanceStore, TransactionStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
      iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   instance_address: instance.address,
      ...>   status: :pending,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, pending} = TransactionStore.create(create_attrs, "unique_id_123")
      iex> pending.status
      :pending
      iex> update_attrs = %{instance_address: instance.address, status: :posted}
      iex> {:ok, posted} = TransactionStore.update(pending.id, update_attrs, "unique_id_456")
      iex> posted.status == :posted && posted.id == pending.id
      iex> {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Event.TransactionEventMap{}} = changeset} = TransactionStore.update(pending.id, update_attrs , "unique_id_456")
      iex> {idempotent_error, _} = Keyword.get(changeset.errors, :update_idempk)
      iex> idempotent_error
      "already exists for this source_idempk"

  """
  @spec update(Ecto.UUID.t(), update_map(), String.t(), Keyword.t()) ::
          {:ok, Transaction.t()}
          | {:error, Ecto.Changeset.t(TransactionEventMap.t()) | String.t()}
  def update(id, %{instance_address: address} = attrs, update_idempotent_id, opts \\ []) do
    update_source = Keyword.get(opts, :update_source, "TransactionStore.update/4")
    retry_on_error = Keyword.get(opts, :retry_on_error, true)
    event = EventStore.get_create_transaction_event(id)

    params = %{
      "instance_address" => address,
      "action" => "update_transaction",
      "source" => event.source,
      "source_idempk" => event.source_idempk,
      "update_idempk" => update_idempotent_id,
      "update_source" => update_source,
      "payload" => Map.delete(attrs, :instance_address)
    }

    response =
      case retry_on_error do
        false -> EventApi.process_from_event_params_no_save_on_error(params)
        _ -> EventApi.process_from_event_params(params)
      end

    case response do
      {:ok, transaction, _event} -> {:ok, transaction}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieves a transaction by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the transaction.

  ## Returns

    - `transaction`: The transaction struct, or `nil` if not found.
  """
  @spec get_by_id(Ecto.UUID.t(), list()) :: Transaction.t() | nil
  def get_by_id(id, preload \\ []) do
    transaction = Repo.get(Transaction, id)

    if transaction != nil and preload != [] do
      Repo.preload(transaction, preload)
    else
      transaction
    end
  end

  @doc """
  Lists all transactions for a given instance.
  The output is paginated.

  ## Parameters

    - `instance_id` - The UUID of the instance.
    - `page` - The page number (defaults to 1).
    - `per_page` - The number of transactions per page (defaults to 40).

  ## Returns

    - A list of transactions.

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.{InstanceStore, TransactionStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
      iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   instance_address: instance.address,
      ...>   status: :posted,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, transaction} = TransactionStore.create(create_attrs, "unique_id_123")
      iex> [trx|_] = TransactionStore.list_all_for_instance_id(instance.id)
      iex> trx.id == transaction.id && trx.status == :posted
      true

      iex> TransactionStore.list_all_for_instance_id(Ecto.UUID.generate(), 2, 10)
      []

      iex> TransactionStore.list_all_for_instance_id(Ecto.UUID.generate(), 0, 1)
      []

      iex> TransactionStore.list_all_for_instance_id(Ecto.UUID.generate(), 1, 0)
      []
  """
  @spec list_all_for_instance_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Transaction.t())
  def list_all_for_instance_id(instance_id, page \\ 1, per_page \\ 40)

  def list_all_for_instance_id(_instance_id, page, per_page) when page < 1 or per_page < 1,
    do: []

  def list_all_for_instance_id(instance_id, page, per_page) do
    from(t in Transaction,
      where: t.instance_id == ^instance_id,
      select: t,
      order_by: [desc: t.inserted_at]
    )
    |> paginate(page, per_page)
    |> Repo.all()
  end

  @doc """
  Lists all transactions for a given instance address. The output is paginated.

  ## Parameters

    - `instance_address` - The address of the instance.
    - `page` - The page number (defaults to 1).
    - `per_page` - The number of transactions per page (defaults to 40).

  ## Returns

    - A list of transactions.

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.{InstanceStore, TransactionStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
      iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   instance_address: instance.address,
      ...>   status: :posted,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, transaction} = TransactionStore.create(create_attrs, "unique_id_123")
      iex> [trx|_] = TransactionStore.list_all_for_instance_address(instance.address)
      iex> trx.id == transaction.id && trx.status == :posted
      true

      iex> TransactionStore.list_all_for_instance_address("NonExistentInstance", 2, 10)
      []

  """
  @spec list_all_for_instance_address(String.t(), non_neg_integer(), non_neg_integer()) ::
          list(Transaction.t())
  def list_all_for_instance_address(instance_address, page \\ 1, per_page \\ 40) do
    instance = DoubleEntryLedger.Stores.InstanceStore.get_by_address(instance_address)

    if instance do
      list_all_for_instance_id(instance.id, page, per_page)
    else
      []
    end
  end

  @doc """
  Lists all transactions for a given instance and account. This function joins the transactions
  with their associated entries, accounts, and the latest balance history entry for each entry.
  The output is paginated.

  ## Parameters

    - `instance_id` - The UUID of the instance.
    - `account_id` - The UUID of the account
    - `page` - The page number (defaults to 1).
    - `per_page` - The number of transactions per page (defaults to 40).

  ## Returns

    - A list of tuples containing the transaction, account, entry, and the latest balance history entry.

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.{InstanceStore, TransactionStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
      iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   instance_address: instance.address,
      ...>   status: :posted,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, transaction1} = TransactionStore.create(create_attrs, "unique_id_123")
      iex> {:ok, transaction2} = TransactionStore.create(create_attrs, "unique_id_456")
      iex> [{trx1, acc1, _ , bh1}, {trx2, acc2, _ , _}| _] = TransactionStore.list_all_for_instance_id_and_account_id(instance.id, asset_account.id)
      iex> trx1.id == transaction2.id && trx1.status == :posted && acc1.id == asset_account.id
      true
      iex> trx2.id == transaction1.id && trx1.status == :posted && acc2.id == asset_account.id
      true
      iex> bh1.available == 200
      true
      iex> # Test pagination
      iex> [{trx3, acc3, _ , _}| _] = tuple_list = TransactionStore.list_all_for_instance_id_and_account_id(instance.id, asset_account.id, 2, 1)
      iex> trx3.id == transaction1.id && trx1.status == :posted && acc3.id == asset_account.id
      true
      iex> length(tuple_list)
      1


      iex> TransactionStore.list_all_for_instance_id_and_account_id(Ecto.UUID.generate(), Ecto.UUID.generate(), 2, 1)
      []
  """
  @spec list_all_for_instance_id_and_account_id(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          list({Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()})
  def list_all_for_instance_id_and_account_id(instance_id, account_id, page \\ 1, per_page \\ 40)

  def list_all_for_instance_id_and_account_id(_instance_id, _account_id, page, per_page)
      when page < 1 or per_page < 1,
      do: []

  def list_all_for_instance_id_and_account_id(instance_id, account_id, page, per_page) do
    from(transaction in Transaction,
      join: entry in assoc(transaction, :entries),
      on: entry.transaction_id == transaction.id,
      as: :entry,
      join: account in assoc(entry, :account),
      on: account.id == entry.account_id,
      left_lateral_join:
        latest_balance_history in subquery(
          from(balance_history in BalanceHistoryEntry,
            where: balance_history.entry_id == parent_as(:entry).id,
            order_by: [desc: balance_history.inserted_at],
            limit: 1,
            select: balance_history
          )
        ),
      on: latest_balance_history.entry_id == entry.id,
      order_by: [desc: transaction.inserted_at],
      where: entry.account_id == ^account_id and transaction.instance_id == ^instance_id,
      select: {transaction, account, entry, latest_balance_history}
    )
    |> paginate(page, per_page)
    |> Repo.all()
  end

  @doc """
  It's like `list_all_for_instance_id_and_account_id/4` but takes instance and account addresses instead of IDs.

  ## Parameters

    - `instance_address` - Address of the instance.
    - `account_address` - Address of the account
    - `page` - The page number (defaults to 1).
    - `per_page` - The number of transactions per page (defaults to 40).

  ## Returns

    - A list of tuples containing the transaction, account, entry, and the latest balance history entry.

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.{InstanceStore, TransactionStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
      iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   instance_address: instance.address,
      ...>   status: :posted,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, transaction1} = TransactionStore.create(create_attrs, "unique_id_123")
      iex> {:ok, transaction2} = TransactionStore.create(create_attrs, "unique_id_456")
      iex> [{trx1, acc1, _ , _}, {trx2, acc2, _ , _}| _] = TransactionStore.list_all_for_instance_address_and_account_address(instance.address, asset_account.address)
      iex> trx1.id == transaction2.id && trx1.status == :posted && acc1.id == asset_account.id
      true
      iex> trx2.id == transaction1.id && trx1.status == :posted && acc2.id == asset_account.id
      true

      iex> TransactionStore.list_all_for_instance_address_and_account_address("NonExistentInstance", "NonExistentAccount", 2, 1)
      []

  """
  def list_all_for_instance_address_and_account_address(
        instance_address,
        account_address,
        page \\ 1,
        per_page \\ 40
      ) do
    instance = DoubleEntryLedger.Stores.InstanceStore.get_by_address(instance_address)

    account =
      DoubleEntryLedger.Stores.AccountStore.get_by_address(instance_address, account_address)

    if instance && account do
      list_all_for_instance_id_and_account_id(instance.id, account.id, page, per_page)
    else
      []
    end
  end
end
