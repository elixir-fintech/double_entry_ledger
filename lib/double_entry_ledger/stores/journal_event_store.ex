defmodule DoubleEntryLedger.Stores.JournalEventStore do
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
  import DoubleEntryLedger.Stores.JournalEventStoreHelper
  import DoubleEntryLedger.Utils.Pagination

  alias DoubleEntryLedger.{Repo, Event, JournalEvent, Account}
  alias DoubleEntryLedger.Stores.AccountStore

  @doc """
  Retrieves an event by its unique ID.

  Returns the event if found, or nil if no event exists with the given ID.

  ## Parameters
    - `id`: The UUID of the event to retrieve

  ## Returns
    - `Event.t()`: The found event
    - `nil`: If no event with the given ID exists
  """
  @spec get_by_id(Ecto.UUID.t()) :: JournalEvent.t() | nil
  def get_by_id(id) do
    JournalEvent
    |> where(id: ^id)
    |> preload([:account])
    |> Repo.one()
  end

  @spec get_by_instance_address_and_id(String.t(), Ecto.UUID.t()) :: JournalEvent.t() | nil
  def get_by_instance_address_and_id(instance_address, id) do
    from(e in JournalEvent,
      join: i in assoc(e, :instance), where: i.address == ^instance_address and e.id == ^id,
      select: e,
      preload: [:account, :instance]
    )
    |> Repo.one()
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
          list(JournalEvent.t())
  def list_all_for_instance_id(instance_id, page \\ 1, per_page \\ 40) do
    from(e in JournalEvent,
      where: e.instance_id == ^instance_id,
      order_by: [desc: e.inserted_at],
      select: e
    )
    |> paginate(page, per_page)
    |> preload([:account])
    |> Repo.all()
  end

  @doc """
  Gets the create account event associated with a specific account.

  ## Parameters
    - `account_id`: ID of the account to get the create event for

  ## Returns
    - `Event.t() | nil`: The create account event if found and processed

  ### Examples
    iex> alias DoubleEntryLedger.Stores.{JournalEventStore, AccountStore, InstanceStore}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
    iex> {:ok, %{id: id}} = AccountStore.create(instance.address, account_data, "unique_id_123")
    iex> event = JournalEventStore.get_create_account_event(id)
    iex> event.account.id
    id
  """
  @spec get_create_account_event(Ecto.UUID.t()) :: Event.t()
  def get_create_account_event(account_id) do
    base_account_query(account_id)
    |> where([e], fragment("?->> 'action' = 'create_account'", e.event_map))
    |> order_by(asc: :inserted_at)
    |> preload([:account])
    |> Repo.one()
  end

  @doc """
  Lists all events associated with a specific account using the Account id.

  ## Parameters
    - `account_id`: ID of the account to list events for

  ## Returns
    - List of Event structs, ordered by insertion time descending

  ## Examples

    iex> alias DoubleEntryLedger.Stores.{JournalEventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> [acc_event | _] = events = JournalEventStore.list_all_for_account_id(asset_account.id)
    iex> #[trx_event, acc_event | _] = events = JournalEventStore.list_all_for_account_id(asset_account.id)
    iex> length(events)
    1
    iex> acc_event.event_map.action
    :create_account
    iex> #trx_event.event_map.action

    iex> JournalEventStore.list_all_for_account_id(Ecto.UUID.generate())
    []

  """
  @spec list_all_for_account_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Event.t())
  def list_all_for_account_id(account_id, page \\ 1, per_page \\ 40) do
    all_processed_events_for_account_id(account_id)
    |> paginate(page, per_page)
    |> preload([:account])
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

    iex> alias DoubleEntryLedger.Stores.{JournalEventStore, AccountStore, InstanceStore, TransactionStore}
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
    iex> #[trx_event, acc_event | _] = events = JournalEventStore.list_all_for_account_address(instance.address, liability_account.address)
    iex> [acc_event| _] = events = JournalEventStore.list_all_for_account_address(instance.address, liability_account.address)
    iex> length(events)
    1
    iex> acc_event.event_map.action
    :create_account
    iex> #trx_event.event_map.action

    iex> alias DoubleEntryLedger.Stores.{JournalEventStore, InstanceStore}
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> JournalEventStore.list_all_for_account_address(instance.address, "nonexistent")

    iex> alias DoubleEntryLedger.Stores.JournalEventStore
    iex> JournalEventStore.list_all_for_account_address("nonexistent", "nonexistent")
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
