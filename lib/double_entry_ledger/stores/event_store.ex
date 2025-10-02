defmodule DoubleEntryLedger.Stores.EventStore do
  @moduledoc """
  Provides functions for managing events in the double-entry ledger system.

  This module serves as the primary interface for all event-related operations, including
  creating, retrieving, processing, and querying events. It manages the complete lifecycle
  of events from creation through processing to completion or failure.

  ## Key Functionality

    * **Event Management**: Create, retrieve, and track events.
    * **Event Processing**: Claim events for processing, mark events as processed or failed.
    * **Event Queries**: Find events by instance, transaction ID, account ID, or other criteria.
    * **Error Handling**: Track and manage errors that occur during event processing.

  ## Usage Examples

  ### Creating and processing a new event
  Events can be created and processed immediately or queued for asynchronous processing.
  If the event is processed immediately, it will create the associated transaction
  and update the event status. If the event processing fails, it will be queued and retried.

      event_params = %{
        "instance_id" => instance.id,
        "action" => "create_transaction",
        "source" => "payment_system",
        "source_idempk" => "txn_123",
        "payload" => %{
          "status" => "pending",
          "entries" => [
            %{"account_id" => cash_account.id, "amount" => 100_00, "currency" => "USD"},
            %{"account_id" => revenue_account.id, "amount" => 100_00, "currency" => "USD"}
          ]
        }
      }

      # create and process the event immediately
      {:ok, transaction, event} = DoubleEntryLedger.Apis.EventApi.process_from_params(event_params)

      # create event for asynchronous processing later
      {:ok, event} = DoubleEntryLedger.Stores.EventStore.create(event_params)

  ### Retrieving events for an instance

      events = DoubleEntryLedger.Stores.EventStore.list_all_for_instance(instance.id)

  ### Retrieving events for a transaction

      events = DoubleEntryLedger.Stores.EventStore.list_all_for_transaction(transaction.id)

  ### Retrieving events for an account

      events = DoubleEntryLedger.Stores.EventStore.list_all_for_account(account.id)

  ### Process event without saving it in the EventStore on error
  If you want more control over error handling, you can process an event without saving it
  in the EventStore on error. This allows you to handle the event processing logic
  without automatically persisting the event, which can be useful for debugging or custom error handling.

      {:ok, transaction, event} = DoubleEntryLedger.Apis.EventApi.process_from_params(event_params, [on_error: :fail])

  ## Implementation Notes

  - The module implements optimistic concurrency control for event claiming and processing,
    ensuring that events are processed exactly once even in high-concurrency environments.
  - All queries are paginated and ordered by insertion time descending for efficient retrieval.
  - Error handling is explicit, with clear return values for all failure modes.
  """
  import Ecto.Query
  import DoubleEntryLedger.Stores.EventStoreHelper
  import DoubleEntryLedger.Utils.Pagination

  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Event, Account}
  alias DoubleEntryLedger.Event.{TransactionEventMap, AccountEventMap}
  alias DoubleEntryLedger.Stores.{AccountStore, InstanceStoreHelper}

  @doc """
  Retrieves an event by its unique ID.

  Returns the event if found, or nil if no event exists with the given ID.

  ## Parameters
    - `id`: The UUID of the event to retrieve

  ## Returns
    - `Event.t()`: The found event
    - `nil`: If no event with the given ID exists
  """
  @spec get_by_id(Ecto.UUID.t()) :: Event.t() | nil
  def get_by_id(id) do
    Event
    |> where(id: ^id)
    |> preload([:event_queue_item, :transactions, :account])
    |> Repo.one()
  end

  @doc """
  Creates a new event in the database.

  ## Parameters
    - `attrs`: Map of attributes for creating the event

  ## Returns
    - `{:ok, event}`: If the event was successfully created
    - `{:error, changeset}`: If validation failed
  """
  @spec create(TransactionEventMap.t() | AccountEventMap.t()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t(Event.t()) | :instance_not_found}
  def create(%{instance_address: address} = attrs) do
    case Multi.new()
         |> Multi.one(:instance, InstanceStoreHelper.build_get_by_address(address))
         |> Multi.insert(:event, fn %{instance: instance} ->
           build_create(attrs, instance.id)
         end)
         |> Repo.transaction() do
      {:ok, %{event: event}} -> {:ok, event}
      {:error, :instance, _reason, _changes} -> {:error, :instance_not_found}
      {:error, :event, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Lists events for a specific instance with pagination.

  ## Parameters
    - `instance_id`: ID of the instance to list events for
    - `page`: Page number for pagination (defaults to 1)
    - `per_page`: Number of events per page (defaults to 40)

  ## Returns
    - List of Event structs, ordered by insertion time descending

  ## Examples

    iex> alias DoubleEntryLedger.Stores.{EventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> TransactionStore.create(instance.address, create_attrs, "unique_id_123")
    iex> length(EventStore.list_all_for_instance_id(instance.id))
    3
    iex> # test pagination
    iex> length(EventStore.list_all_for_instance_id(instance.id, 2, 2))
    1

  """
  @spec list_all_for_instance_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Event.t())
  def list_all_for_instance_id(instance_id, page \\ 1, per_page \\ 40) do
    from(e in Event,
      where: e.instance_id == ^instance_id,
      order_by: [desc: e.inserted_at],
      select: e
    )
    |> paginate(page, per_page)
    |> preload([:event_queue_item, :transactions, :account])
    |> Repo.all()
  end

  @doc """
  Lists all events associated with a specific transaction.

  ## Parameters
    - `transaction_id`: ID of the transaction to list events for

  ## Returns
    - List of Event structs, ordered by insertion time descending

  ## Examples

    iex> alias DoubleEntryLedger.Stores.{EventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> TransactionStore.update(instance.address, id, %{status: :posted}, "unique_id_123")
    iex> length(EventStore.list_all_for_transaction_id(id))
    2
  """
  @spec list_all_for_transaction_id(Ecto.UUID.t()) :: list(Event.t())
  def list_all_for_transaction_id(transaction_id) do
    base_transaction_query(transaction_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets the create transaction event associated with a specific transaction.

  ## Parameters
    - `transaction_id`: ID of the transaction to get the create event for

  ## Returns

    - `Event.t() | nil`: The create transaction event if found and processed

  ## Examples

    iex> alias DoubleEntryLedger.Stores.{EventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> {:ok, %{id: id}} = TransactionStore.create(instance.address, create_attrs, "unique_id_123")
    iex> event = EventStore.get_create_transaction_event(id)
    iex> [%{id: trx_id} | _] = event.transactions
    iex> trx_id
    id

  """
  @spec get_create_transaction_event(Ecto.UUID.t()) :: Event.t()
  def get_create_transaction_event(transaction_id) do
    base_transaction_query(transaction_id)
    |> join(:inner, [e], eqi in assoc(e, :event_queue_item))
    |> where([e], e.action == :create_transaction)
    |> where([_, _, eqi], eqi.status == :processed)
    |> order_by(asc: :inserted_at)
    |> Repo.one()
  end

  @doc """
  Gets the create account event associated with a specific account.

  ## Parameters
    - `account_id`: ID of the account to get the create event for

  ## Returns
    - `Event.t() | nil`: The create account event if found and processed

  ### Examples
    iex> alias DoubleEntryLedger.Stores.{EventStore, AccountStore, InstanceStore}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
    iex> {:ok, %{id: id}} = AccountStore.create(instance.address, account_data, "unique_id_123")
    iex> event = EventStore.get_create_account_event(id)
    iex> event.account.id
    id
  """
  @spec get_create_account_event(Ecto.UUID.t()) :: Event.t()
  def get_create_account_event(account_id) do
    base_account_query(account_id)
    |> join(:inner, [e], eqi in assoc(e, :event_queue_item))
    |> where([e], e.action == :create_account)
    |> where([_, _, eqi], eqi.status == :processed)
    |> order_by(asc: :inserted_at)
    |> preload([:event_queue_item, :transactions, :account])
    |> Repo.one()
  end

  @doc """
  Lists all events associated with a specific account using the Account id.

  ## Parameters
    - `account_id`: ID of the account to list events for

  ## Returns
    - List of Event structs, ordered by insertion time descending

  ## Examples

    iex> alias DoubleEntryLedger.Stores.{EventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> TransactionStore.create(instance.address, create_attrs, "unique_id_123")
    iex> [trx_event, acc_event | _] = events = EventStore.list_all_for_account_id(asset_account.id)
    iex> length(events)
    2
    iex> trx_event.action
    :create_transaction
    iex> acc_event.action
    :create_account

    iex> EventStore.list_all_for_account_id(Ecto.UUID.generate())
    []

  """
  @spec list_all_for_account_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Event.t())
  def list_all_for_account_id(account_id, page \\ 1, per_page \\ 40) do
    all_processed_events_for_account_id(account_id)
    |> paginate(page, per_page)
    |> preload([:event_queue_item, :transactions, :account])
    |> Repo.all()
  end

  @doc """
  Lists all events associated with a specific account using the Account address

  ## Parameters
    - `instance_address`: Address if the instance the account is on
    - `address`: Address of the account to list events for

  ## Returns
    - List of Event structs, ordered by insertion time descending

  ## Examples

    iex> alias DoubleEntryLedger.Stores.{EventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> TransactionStore.create(instance.address, create_attrs, "unique_id_123")
    iex> [trx_event, acc_event | _] = events = EventStore.list_all_for_account_address(instance.address, liability_account.address)
    iex> length(events)
    2
    iex> trx_event.action
    :create_transaction
    iex> acc_event.action
    :create_account

    iex> alias DoubleEntryLedger.Stores.{EventStore, InstanceStore}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> EventStore.list_all_for_account_address(instance.address, "nonexistent")

    iex> alias DoubleEntryLedger.Stores.EventStore
    iex> EventStore.list_all_for_account_address("nonexistent", "nonexistent")
    []

  """
  @spec list_all_for_account_address(String.t(), String.t()) :: list(Event.t())
  def list_all_for_account_address(instance_address, address) do
    case AccountStore.get_by_address(instance_address, address) do
      %Account{id: id} -> list_all_for_account_id(id)
      _ -> []
    end
  end
end
