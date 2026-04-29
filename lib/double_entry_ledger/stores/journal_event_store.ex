defmodule DoubleEntryLedger.Stores.JournalEventStore do
  @moduledoc """
  Provides read-only queries over journal events in the double-entry ledger system.

  Journal events are immutable, append-only records emitted as a side effect of
  successful command processing. They are the audit trail for state changes in the
  ledger (account creation, transaction creation, transaction updates). This module
  exposes paginated queries for retrieving journal events by instance, account, or
  transaction scope.

  ## Key Functionality

    * **Journal Event Retrieval**: Look up individual journal events by ID.
    * **Scoped Journal Event Queries**: List events for an instance, account, or
      transaction, with cursor pagination via `Flop`.
    * **Account-Create Event Lookup**: Fetch the `:create_account` event for a given
      account (useful for surfacing provenance metadata).

  ## Usage Examples

  ### Producing journal events

  Journal events are emitted automatically when a command is processed successfully.
  They are not created directly — use the command pipeline (see
  `DoubleEntryLedger.Apis.CommandApi` or `DoubleEntryLedger.Stores.CommandStore`) to
  produce events.

  ### Retrieving events for an instance

      {:ok, {events, meta}} = DoubleEntryLedger.Stores.JournalEventStore.list_for_instance(instance.id)

  ### Retrieving events for a transaction

      {:ok, {events, meta}} = DoubleEntryLedger.Stores.JournalEventStore.list_for_transaction(transaction.id)

  ### Retrieving events for an account

      {:ok, {events, meta}} = DoubleEntryLedger.Stores.JournalEventStore.list_for_account(account.id)

  ## Implementation Notes

  - All list queries return `{:ok, {events, Flop.Meta.t()}}` on success and
    `{:error, Flop.Meta.t()}` when the supplied params fail validation.
  - Queries preload commonly joined associations (`:account`, `:transaction`) to
    avoid N+1 access patterns in callers.
  """
  import Ecto.Query
  import DoubleEntryLedger.Stores.JournalEventStoreHelper

  alias DoubleEntryLedger.{Account, Command, Instance, JournalEvent, Transaction}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.AccountStore

  @doc """
  Retrieves an event by its unique ID.

  Returns the event if found, or nil if no event exists with the given ID.

  ## Parameters
    - `id`: The UUID of the event to retrieve

  ## Returns
    - `Command.t()`: The found event
    - `nil`: If no event with the given ID exists
  """
  @spec get_by_id(Ecto.UUID.t()) :: JournalEvent.t() | nil
  def get_by_id(id) do
    JournalEvent
    |> where(id: ^id)
    |> preload([:account, :transaction])
    |> Repo.one()
  end

  @spec get_by_instance_address_and_id(String.t(), Ecto.UUID.t()) :: JournalEvent.t() | nil
  def get_by_instance_address_and_id(instance_address, id) do
    from(e in JournalEvent,
      join: i in assoc(e, :instance),
      where: i.address == ^instance_address and e.id == ^id,
      select: e,
      preload: [:account, :instance, :transaction]
    )
    |> Repo.one()
  end

  @doc """
  Lists journal events for an instance with cursor pagination via Flop.

  Accepts either an `%Instance{}` struct or its UUID string. Preloads `:account`
  and `:transaction` on each event.

  ## Parameters

    - `instance_or_id` (`Instance.t() | Ecto.UUID.t()`): Parent instance.
    - `flop_params` (map, optional): Flop params. No filterable fields (JSONB `command_map` filtering deferred).

  ## Returns

    - `{:ok, {[JournalEvent.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, a1} = AccountStore.create(instance.address, account_data, "u1")
      iex> {:ok, a2} = AccountStore.create(instance.address, %{account_data | address: "Liab:Account", type: :liability}, "u2")
      iex> create_attrs = %{status: :posted, entries: [
      ...>   %{account_address: a1.address, amount: 100, currency: :USD},
      ...>   %{account_address: a2.address, amount: 100, currency: :USD}]}
      iex> {:ok, _} = TransactionStore.create(instance.address, create_attrs, "idem-je-a")
      iex> {:ok, {events, %Flop.Meta{}}} = JournalEventStore.list_for_instance(instance)
      iex> # 2 :create_account events (one per AccountStore.create) + 1 :create_transaction event
      iex> length(events)
      3
  """
  @spec list_for_instance(Instance.t() | Ecto.UUID.t(), map()) ::
          {:ok, {[JournalEvent.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_instance(instance_or_id, flop_params \\ %{})

  def list_for_instance(%Instance{id: id}, flop_params),
    do: list_for_instance(id, flop_params)

  def list_for_instance(id, flop_params) when is_binary(id) do
    from(e in JournalEvent,
      where: e.instance_id == ^id,
      preload: [:account, :transaction]
    )
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: JournalEvent)
  end

  @doc """
  Gets the create account event associated with a specific account.

  ## Parameters
    - `account_id`: ID of the account to get the create event for

  ## Returns
    - `Command.t() | nil`: The create account event if found and processed

  ### Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, %{id: id}} = AccountStore.create(instance.address, account_data, "unique_id_123")
      iex> event = JournalEventStore.get_create_account_event(id)
      iex> event.account.id
      id

  """
  @spec get_create_account_event(Ecto.UUID.t()) :: Command.t()
  def get_create_account_event(account_id) do
    base_account_query(account_id)
    |> where([e], fragment("?->> 'action' = 'create_account'", e.command_map))
    |> order_by(asc: :inserted_at)
    |> preload([:account])
    |> Repo.one()
  end

  @doc """
  Lists journal events for an account with cursor pagination via Flop.

  Accepts either an `%Account{}` struct or its UUID string. Preloads `:account`.

  ## Parameters

    - `account_or_id` (`Account.t() | Ecto.UUID.t()`): Scoping account.
    - `flop_params` (map, optional): Flop params.

  ## Returns

    - `{:ok, {[JournalEvent.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, a1} = AccountStore.create(instance.address, account_data, "u1")
      iex> {:ok, _a2} = AccountStore.create(instance.address, %{account_data | address: "Liab:Account", type: :liability}, "u2")
      iex> {:ok, {events, %Flop.Meta{}}} = JournalEventStore.list_for_account(a1)
      iex> Enum.map(events, & &1.command_map.action)
      [:create_account]
  """
  @spec list_for_account(Account.t() | Ecto.UUID.t(), map()) ::
          {:ok, {[JournalEvent.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_account(account_or_id, flop_params \\ %{})

  def list_for_account(%Account{id: id}, flop_params),
    do: list_for_account(id, flop_params)

  def list_for_account(id, flop_params) when is_binary(id) do
    all_processed_events_for_account_id(id)
    |> exclude(:order_by)
    |> preload([:account])
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: JournalEvent)
  end

  @doc """
  Lists journal events for an account identified by (instance_address, account_address)
  with cursor pagination.

  Returns an empty first page if the pair does not resolve to an existing account.

  ## Parameters

    - `instance_address` (`String.t()`): Address of the parent instance.
    - `account_address` (`String.t()`): Address of the scoping account.
    - `flop_params` (map, optional): Flop params.

  ## Returns

    - `{:ok, {[JournalEvent.t()], Flop.Meta.t()}}` on success (empty page if the pair is unknown).
    - `{:error, Flop.Meta.t()}` on invalid params.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> {:ok, {[], %Flop.Meta{}}} = JournalEventStore.list_for_account_address(instance.address, "no:such:account")
  """
  @spec list_for_account_address(String.t(), String.t(), map()) ::
          {:ok, {[JournalEvent.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_account_address(instance_address, account_address, flop_params \\ %{}) do
    case AccountStore.get_by_address(instance_address, account_address) do
      %Account{id: id} ->
        list_for_account(id, flop_params)

      _ ->
        from(e in JournalEvent, where: false)
        |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: JournalEvent)
    end
  end

  @doc """
  Lists journal events for a transaction with cursor pagination via Flop.

  Accepts either a `%Transaction{}` struct or its UUID string.

  ## Parameters

    - `transaction_or_id` (`Transaction.t() | Ecto.UUID.t()`): Scoping transaction.
    - `flop_params` (map, optional): Flop params.

  ## Returns

    - `{:ok, {[JournalEvent.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` on invalid params.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
      iex> {:ok, a1} = AccountStore.create(instance.address, account_data, "u1")
      iex> {:ok, a2} = AccountStore.create(instance.address, %{account_data | address: "Liab:Account", type: :liability}, "u2")
      iex> attrs = %{status: :pending, entries: [
      ...>   %{account_address: a1.address, amount: 100, currency: :USD},
      ...>   %{account_address: a2.address, amount: 100, currency: :USD}]}
      iex> {:ok, %{id: id}} = TransactionStore.create(instance.address, attrs, "idem-je-b")
      iex> TransactionStore.update(instance.address, id, %{status: :posted}, "idem-je-b")
      iex> {:ok, {events, %Flop.Meta{}}} = JournalEventStore.list_for_transaction(id)
      iex> length(events)
      2
  """
  @spec list_for_transaction(Transaction.t() | Ecto.UUID.t(), map()) ::
          {:ok, {[JournalEvent.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_transaction(transaction_or_id, flop_params \\ %{})

  def list_for_transaction(%Transaction{id: id}, flop_params),
    do: list_for_transaction(id, flop_params)

  def list_for_transaction(id, flop_params) when is_binary(id) do
    base_transaction_query(id)
    |> DoubleEntryLedger.Flop.validate_and_run(flop_params, for: JournalEvent)
  end

  @doc """
  Gets the create transaction journal event associated with a specific transaction.

  ## Parameters
    - `transaction_id`: ID of the transaction to get the create event for

  ## Returns

    - `JournalEvent.t() | nil`: The create transaction journal event if found

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
      iex> {:ok, %{id: id}} = TransactionStore.create(instance.address, create_attrs, "unique_id_123")
      iex> event = JournalEventStore.get_create_transaction_journal_event(id)
      iex> %{id: trx_id} = event.transaction
      iex> trx_id
      id

  """
  @spec get_create_transaction_journal_event(Ecto.UUID.t()) :: Command.t()
  def get_create_transaction_journal_event(transaction_id) do
    base_transaction_query(transaction_id)
    |> where([je], fragment("?->> 'action' = 'create_transaction'", je.command_map))
    |> Repo.one()
  end
end
