defmodule DoubleEntryLedger.EventStore do
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
      {:ok, transaction, event} = DoubleEntryLedger.EventStore.process_from_event_params(event_params)

      # create event for asynchronous processing later
      {:ok, event} = DoubleEntryLedger.EventStore.create(event_params)

  ### Retrieving events for an instance

      events = DoubleEntryLedger.EventStore.list_all_for_instance(instance.id)

  ### Retrieving events for a transaction

      events = DoubleEntryLedger.EventStore.list_all_for_transaction(transaction.id)

  ### Retrieving events for an account

      events = DoubleEntryLedger.EventStore.list_all_for_account(account.id)

  ### Process event without saving it in the EventStore on error
  If you want more control over error handling, you can process an event without saving it
  in the EventStore on error. This allows you to handle the event processing logic
  without automatically persisting the event, which can be useful for debugging or custom error handling.

      {:ok, transaction, event} = DoubleEntryLedger.EventStore.process_from_event_params_no_save_on_error(event_params)

  ## Implementation Notes

  - The module implements optimistic concurrency control for event claiming and processing,
    ensuring that events are processed exactly once even in high-concurrency environments.
  - All queries are paginated and ordered by insertion time descending for efficient retrieval.
  - Error handling is explicit, with clear return values for all failure modes.
  """
  import Ecto.Query
  import DoubleEntryLedger.EventStoreHelper
  import DoubleEntryLedger.PaginationHelper

  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Event, InstanceStoreHelper, AccountStore, Account}
  alias DoubleEntryLedger.Event.{TransactionEventMap, AccountEventMap}
  alias DoubleEntryLedger.EventWorker

  @account_actions Event.actions(:account) |> Enum.map(&Atom.to_string/1)
  @transaction_actions Event.actions(:transaction) |> Enum.map(&Atom.to_string/1)

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
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | :instance_not_found}
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
  Processes an event from provided parameters, handling the entire workflow.
  This only works for parameters that translate into a `TransactionEventMap`.

  This function creates a TransactionEventMap from the parameters, then processes it through
  the EventWorker to create both an event record in the EventStore and creates the necessary projections.

  If the processing fails, it will return an error tuple with details about the failure.
  The event is saved to the EventQueue and then retried later.

  ## Supported Actions

  ### Transaction Actions
  - `"create_transaction"` - Creates new double-entry transactions with balanced entries
  - `"update_transaction"` - Updates existing pending transactions

  ## Parameters
    - `event_params`: Map containing event parameters including action and payload data

  ## Returns
    - `{:ok, transaction, event}`: If a transaction event was successfully processed
    - `{:error, event}`: If the event processing failed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons

  ### Examples

    iex> alias DoubleEntryLedger.{InstanceStore, EventStore, AccountStore, Repo}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
    iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
    iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
    iex> {:ok, transaction, event} = EventStore.process_from_event_params(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_transaction",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_123",
    ...>   "payload" => %{
    ...>     status: :posted,
    ...>     entries: [
    ...>       %{account_address: asset_account.address, amount: 100, currency: :USD},
    ...>       %{account_address: liability_account.address, amount: 100, currency: :USD}
    ...>     ]
    ...>   }
    ...> })
    iex> [trx | _] =  (event |> Repo.preload(:transactions)).transactions
    iex> trx.id == transaction.id
    true
  """
  @spec process_from_event_params(map()) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_from_event_params(%{"action" => action} = event_params)
      when action in @transaction_actions do
    case TransactionEventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end

  @doc """
  Same as `process_from_event_params/1`, but does not save the event on error.

  This function provides an alternative processing strategy for scenarios where you want
  to validate and process events but avoid an automated retry. You will need to keep track
  of failed events for audit purposes.

  ## Supported Actions

  Same as `process_from_event_params/1` - supports both transaction and account actions.

  ## Parameters
    - `event_params`: Map containing event parameters including action and payload data

  ## Returns
    - `{:ok, transaction, event}`: If a transaction event was successfully processed
    - `{:ok, account, event}`: If an account event was successfully processed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons

  ### Examples

    iex> alias DoubleEntryLedger.{InstanceStore, EventStore, Repo}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> {:ok, account, event} = EventStore.process_from_event_params_no_save_on_error(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_account",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_123",
    ...>   "payload" => %{
    ...>     type: :asset,
    ...>     address: "asset:owner:1",
    ...>     currency: :EUR
    ...>   }
    ...> })
    iex> (event |> Repo.preload(:account)).account.id == account.id
    true

  """
  @spec process_from_event_params_no_save_on_error(map()) ::
          EventWorker.success_tuple() | {:error, Ecto.Changeset.t() | String.t()}
  def process_from_event_params_no_save_on_error(%{"action" => action} = event_params)
      when action in @account_actions do
    case AccountEventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event_no_save_on_error(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end

  def process_from_event_params_no_save_on_error(%{"action" => action} = event_params)
      when action in @transaction_actions do
    case TransactionEventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event_no_save_on_error(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
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

    iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, TransactionStore, EventStore}
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
    iex> TransactionStore.create(create_attrs, "unique_id_123")
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

    iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, TransactionStore, EventStore}
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
    iex> {:ok, %{id: id}} = TransactionStore.create(create_attrs, "unique_id_123")
    iex> TransactionStore.update(id, %{instance_address: instance.address, status: :posted}, "unique_id_123")
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

    iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, TransactionStore, EventStore}
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
    iex> {:ok, %{id: id}} = TransactionStore.create(create_attrs, "unique_id_123")
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
    iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, EventStore}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
    iex> {:ok, %{id: id}} = AccountStore.create(account_data, "unique_id_123")
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

    iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, TransactionStore, EventStore}
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
    iex> TransactionStore.create(create_attrs, "unique_id_123")
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
  @spec list_all_for_account_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) :: list(Event.t())
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

    iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, TransactionStore, EventStore}
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
    iex> TransactionStore.create(create_attrs, "unique_id_123")
    iex> [trx_event, acc_event | _] = events = EventStore.list_all_for_account_address(instance.address, liability_account.address)
    iex> length(events)
    2
    iex> trx_event.action
    :create_transaction
    iex> acc_event.action
    :create_account

    iex> alias DoubleEntryLedger.{InstanceStore, EventStore}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> EventStore.list_all_for_account_address(instance.address, "nonexistent")

    iex> alias DoubleEntryLedger.EventStore
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
