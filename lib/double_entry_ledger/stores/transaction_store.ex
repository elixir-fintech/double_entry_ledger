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

      {:ok, {transactions, meta}} = DoubleEntryLedger.Stores.TransactionStore.list_for_instance(instance.id)

  Getting transactions for an account in an instance (each element is a
  `{Transaction, Account, Entry, BalanceHistoryEntry}` tuple):

      {:ok, {tuples, meta}} =
        DoubleEntryLedger.Stores.TransactionStore.list_for_instance_and_account(instance.id, account.id)
      # tuples is e.g. [{%Transaction{}, %Account{}, %Entry{}, %BalanceHistoryEntry{}}, ...]

  """
  import Ecto.Query

  alias DoubleEntryLedger.Utils.Currency

  alias DoubleEntryLedger.{
    Account,
    Entry,
    Instance,
    Repo,
    Transaction,
    BalanceHistoryEntry
  }

  alias DoubleEntryLedger.Stores.JournalEventStore
  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.Command.TransactionCommandMap

  @type entry_map() :: %{
          account_address: String.t(),
          amount: integer(),
          currency: Currency.currency_atom()
        }

  @type create_map() :: %{
          status: Transaction.state(),
          entries: list(entry_map())
        }

  @type update_map() :: %{
          status: Transaction.state(),
          entries: list(entry_map()) | nil
        }

  @doc """
  Creates a new transaction with the given attributes. If the creation fails, the command is saved
  to the command queue and retried later.

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
      - `:source` Defaults to "transaction_store-create".
      - `:on_error`
        - :retry (default) The command will be saved in the CommandQueue for retry after a processing error.
        - :fail if you want to handle errors manually without saving the command to the CommandQueue.
  ## Returns

    - `{:ok, transaction}`: On successful creation, returns the created transaction.
    - `{:error, reason}`: On failure, returns an error tuple with the reason.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, asset_account} = AccountStore.create(instance.address, account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(instance.address, %{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   status: :posted,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, transaction} = TransactionStore.create(instance.address, create_attrs, "unique_id_123")
      iex> transaction.status
      :posted
      iex> {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Command.TransactionCommandMap{}} = changeset} = TransactionStore.create(instance.address, create_attrs , "unique_id_123")
      iex> {idempotent_error, _} = Keyword.get(changeset.errors, :key_hash)
      iex> idempotent_error
      "idempotency violation"

  """
  @spec create(String.t(), create_map(), String.t(),
          on_error: CommandApi.on_error(),
          source: String.t()
        ) ::
          {:ok, Transaction.t()}
          | {:error, Ecto.Changeset.t(TransactionCommandMap.t()) | String.t()}
  def create(instance_address, attrs, idempotent_id, opts \\ []) do
    source = Keyword.get(opts, :source, "transaction_store-create")
    on_error = Keyword.get(opts, :on_error, :retry)

    params = %{
      "instance_address" => instance_address,
      "action" => "create_transaction",
      "source" => source,
      "source_idempk" => idempotent_id,
      "payload" => attrs
    }

    CommandApi.process_from_params(params, Keyword.new(on_error: on_error))
    |> case do
      {:ok, transaction, _event} -> {:ok, transaction}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates a transaction with the given attributes. If the update fails, the command is saved
  to the command queue and retried later.

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
      - `:update_source` Defaults to "transaction_store-update". Use if the source of the change is different from the initial source when creating the command.
      - `:on_error`
        - :retry (default) The command will be saved in the CommandQueue for retry after a processing error.
        - :fail if you want to handle errors manually without saving the command to the CommandQueue.

  ## Returns

    - `{:ok, transaction}`: On successful creation, returns the created transaction.
    - `{:error, reason}`: On failure, returns an error tuple with the reason.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, asset_account} = AccountStore.create(instance.address, account_data, "unique_id_123")
      iex> {:ok, liability_account} = AccountStore.create(instance.address, %{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
      iex> create_attrs = %{
      ...>   status: :pending,
      ...>   entries: [
      ...>     %{account_address: asset_account.address, amount: 100, currency: :USD},
      ...>     %{account_address: liability_account.address, amount: 100, currency: :USD}
      ...>   ]}
      iex> {:ok, pending} = TransactionStore.create(instance.address, create_attrs, "unique_id_123")
      iex> pending.status
      :pending
      iex> update_attrs = %{status: :posted}
      iex> {:ok, posted} = TransactionStore.update(instance.address, pending.id, update_attrs, "unique_id_456")
      iex> posted.status == :posted && posted.id == pending.id
      iex> {:error, %Ecto.Changeset{data: %DoubleEntryLedger.Command.TransactionCommandMap{}} = changeset} = TransactionStore.update(instance.address, pending.id, update_attrs , "unique_id_456")
      iex> {idempotent_error, _} = Keyword.get(changeset.errors, :key_hash)
      iex> idempotent_error
      "idempotency violation"

  """
  @spec update(String.t(), Ecto.UUID.t(), update_map(), String.t(),
          on_error: CommandApi.on_error(),
          update_source: String.t()
        ) ::
          {:ok, Transaction.t()}
          | {:error, Ecto.Changeset.t(TransactionCommandMap.t()) | String.t()}
  def update(instance_address, id, attrs, update_idempotent_id, opts \\ []) do
    update_source = Keyword.get(opts, :update_source, "transaction_store-update")
    on_error = Keyword.get(opts, :on_error, :retry)
    %{command_map: command_map} = JournalEventStore.get_create_transaction_journal_event(id)

    params = %{
      "instance_address" => instance_address,
      "action" => "update_transaction",
      "source" => command_map.source,
      "source_idempk" => command_map.source_idempk,
      "update_idempk" => update_idempotent_id,
      "update_source" => update_source,
      "payload" => attrs
    }

    CommandApi.process_from_params(params, Keyword.new(on_error: on_error))
    |> case do
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
  Lists transactions for an instance with cursor pagination.

  Accepts an `%Instance{}` struct or its UUID string.

  ## Parameters

    - `instance_or_id` (`Instance.t() | Ecto.UUID.t()`): Parent instance or its id.
    - `flop_params` (map, optional): Flop params. Filterable: `:status`.

  ## Returns

    - `{:ok, {[Transaction.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, a1} = AccountStore.create(instance.address, account_data, "u1")
      iex> {:ok, a2} = AccountStore.create(instance.address, %{account_data | address: "Liab:Account", type: :liability}, "u2")
      iex> attrs = %{status: :posted, entries: [
      ...>   %{account_address: a1.address, amount: 100, currency: :USD},
      ...>   %{account_address: a2.address, amount: 100, currency: :USD}]}
      iex> {:ok, _} = TransactionStore.create(instance.address, attrs, "idem-1")
      iex> {:ok, {[trx], %Flop.Meta{}}} = TransactionStore.list_for_instance(instance)
      iex> trx.status
      :posted
  """
  @spec list_for_instance(Instance.t() | Ecto.UUID.t(), map()) ::
          {:ok, {[Transaction.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_instance(instance_or_id, flop_params \\ %{})

  def list_for_instance(%Instance{id: id}, flop_params),
    do: list_for_instance(id, flop_params)

  def list_for_instance(id, flop_params) when is_binary(id) do
    from(t in Transaction, where: t.instance_id == ^id)
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: Transaction)
  end

  @doc """
  Lists transactions for an instance address with cursor pagination.

  ## Parameters

    - `instance_address` (`String.t()`): Address of the parent instance.
    - `flop_params` (map, optional): Flop params. Filterable: `:status`.

  ## Returns

    - `{:ok, {[Transaction.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.
  """
  @spec list_for_instance_address(String.t(), map()) ::
          {:ok, {[Transaction.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_instance_address(instance_address, flop_params \\ %{}) do
    from(t in Transaction,
      join: i in assoc(t, :instance),
      where: i.address == ^instance_address
    )
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: Transaction)
  end

  @doc """
  Lists transactions scoped to an instance+account, returning tuples of
  `{Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()}` where
  the `BalanceHistoryEntry` is the latest history row for each entry (via a
  lateral join).

  Accepts `%Instance{}` or its UUID string for the first arg and `%Account{}`
  or its UUID string for the second.

  ## Parameters

    - `instance_or_id` (`Instance.t() | Ecto.UUID.t()`): Parent instance.
    - `account_or_id` (`Account.t() | Ecto.UUID.t()`): Scoping account.
    - `flop_params` (map, optional): Flop params. Filterable: `:status`.

  ## Returns

    - `{:ok, {[{Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()}], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.
  """
  @spec list_for_instance_and_account(
          Instance.t() | Ecto.UUID.t(),
          Account.t() | Ecto.UUID.t(),
          map()
        ) ::
          {:ok,
           {[{Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()}], Flop.Meta.t()}}
          | {:error, Flop.Meta.t()}
  def list_for_instance_and_account(instance_or_id, account_or_id, flop_params \\ %{})

  def list_for_instance_and_account(%Instance{id: inst_id}, %Account{id: acc_id}, p),
    do: list_for_instance_and_account(inst_id, acc_id, p)

  def list_for_instance_and_account(%Instance{id: inst_id}, acc_id, p) when is_binary(acc_id),
    do: list_for_instance_and_account(inst_id, acc_id, p)

  def list_for_instance_and_account(inst_id, %Account{id: acc_id}, p) when is_binary(inst_id),
    do: list_for_instance_and_account(inst_id, acc_id, p)

  def list_for_instance_and_account(inst_id, acc_id, flop_params)
      when is_binary(inst_id) and is_binary(acc_id) do
    from(transaction in Transaction,
      join: entry in assoc(transaction, :entries),
      as: :entry,
      join: account in assoc(entry, :account),
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
      where: entry.account_id == ^acc_id and transaction.instance_id == ^inst_id,
      select: {transaction, account, entry, latest_balance_history}
    )
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: Transaction)
  end

  @doc """
  Address-keyed variant of `list_for_instance_and_account/3`. Returns the
  same `{Transaction, Account, Entry, BalanceHistoryEntry}` 4-tuples.

  ## Parameters

    - `instance_address` (`String.t()`): Address of the parent instance.
    - `account_address` (`String.t()`): Address of the scoping account.
    - `flop_params` (map, optional): Flop params. Filterable: `:status`.

  ## Returns

    - `{:ok, {[{Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()}], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.
  """
  @spec list_for_instance_and_account_address(String.t(), String.t(), map()) ::
          {:ok,
           {[{Transaction.t(), Account.t(), Entry.t(), BalanceHistoryEntry.t()}], Flop.Meta.t()}}
          | {:error, Flop.Meta.t()}
  def list_for_instance_and_account_address(
        instance_address,
        account_address,
        flop_params \\ %{}
      ) do
    from(transaction in Transaction,
      join: i in assoc(transaction, :instance),
      join: entry in assoc(transaction, :entries),
      as: :entry,
      join: account in assoc(entry, :account),
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
      where: i.address == ^instance_address and account.address == ^account_address,
      select: {transaction, account, entry, latest_balance_history}
    )
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: Transaction)
  end
end
