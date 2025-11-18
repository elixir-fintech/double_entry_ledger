defmodule DoubleEntryLedger.Stores.CommandStore do
  @moduledoc """
  Provides functions for managing events in the double-entry ledger system.

  This module serves as the primary interface for all event-related operations, including
  creating, retrieving, processing, and querying events. It manages the complete lifecycle
  of events from creation through processing to completion or failure.

  ## Key Functionality

    * **Command Management**: Create, retrieve, and track events.
    * **Command Processing**: Claim events for processing, mark events as processed or failed.
    * **Command Queries**: Find events by instance, transaction ID, account ID, or other criteria.
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
      {:ok, transaction, event} = DoubleEntryLedger.Apis.CommandApi.process_from_params(event_params)

      # create event for asynchronous processing later
      {:ok, event} = DoubleEntryLedger.Stores.CommandStore.create(event_params)

  ### Retrieving events for an instance

      events = DoubleEntryLedger.Stores.CommandStore.list_all_for_instance(instance.id)

  ### Retrieving events for a transaction

      events = DoubleEntryLedger.Stores.CommandStore.list_all_for_transaction(transaction.id)

  ### Retrieving events for an account

      events = DoubleEntryLedger.Stores.CommandStore.list_all_for_account(account.id)

  ### Process event without saving it in the CommandStore on error
  If you want more control over error handling, you can process an event without saving it
  in the CommandStore on error. This allows you to handle the event processing logic
  without automatically persisting the event, which can be useful for debugging or custom error handling.

      {:ok, transaction, event} = DoubleEntryLedger.Apis.CommandApi.process_from_params(event_params, [on_error: :fail])

  ## Implementation Notes

  - The module implements optimistic concurrency control for event claiming and processing,
    ensuring that events are processed exactly once even in high-concurrency environments.
  - All queries are paginated and ordered by insertion time descending for efficient retrieval.
  - Error handling is explicit, with clear return values for all failure modes.
  """
  import Ecto.Query
  import DoubleEntryLedger.Stores.CommandStoreHelper
  import DoubleEntryLedger.Utils.Pagination

  alias Ecto.Multi
  alias DoubleEntryLedger.{Repo, Command, PendingTransactionLookup}
  alias DoubleEntryLedger.Command.{TransactionEventMap, AccountCommandMap}
  alias DoubleEntryLedger.Stores.InstanceStoreHelper

  @doc """
  Retrieves an event by its unique ID.

  Returns the event if found, or nil if no event exists with the given ID.

  ## Parameters
    - `id`: The UUID of the event to retrieve

  ## Returns
    - `Command.t()`: The found event
    - `nil`: If no event with the given ID exists
  """
  @spec get_by_id(Ecto.UUID.t()) :: Command.t() | nil
  def get_by_id(id) do
    Command
    |> where(id: ^id)
    |> preload([:command_queue_item, :transaction])
    |> Repo.one()
  end

  @spec get_by_instance_address_and_id(String.t(), Ecto.UUID.t()) :: Command.t() | nil
  def get_by_instance_address_and_id(instance_address, id) do
    from(e in Command,
      join: i in assoc(e, :instance),
      where: i.address == ^instance_address and e.id == ^id,
      select: e,
      preload: [:command_queue_item, :transaction, :instance]
    )
    |> Repo.one()
  end

  @doc """
  Creates a new event in the database.

  ## Parameters
    - `attrs`: Map of attributes for creating the event

  ## Returns
    - `{:ok, event}`: If the event was successfully created
    - `{:error, changeset}`: If validation failed

  ## Examples

    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
    iex> {:ok, asset_account} = AccountStore.create(instance.address, account_data, "unique_id_123")
    iex> {:ok, liability_account} = AccountStore.create(instance.address, %{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
    iex> transaction_map = %TransactionEventMap{
    ...>   instance_address: instance.address,
    ...>   action: :create_transaction,
    ...>   source: "from-somewhere",
    ...>   source_idempk: "unique_1234",
    ...>   payload: %{
    ...>     status: :pending,
    ...>     entries: [
    ...>       %{account_address: asset_account.address, amount: 100, currency: :USD},
    ...>       %{account_address: liability_account.address, amount: 100, currency: :USD}
    ...>     ]}}
    iex>   {:ok, command} = CommandStore.create(transaction_map)
    iex>  command.command_queue_item.status
    :pending
  """
  @spec create(TransactionEventMap.t() | AccountCommandMap.t()) ::
          {:ok, Command.t()} | {:error, Ecto.Changeset.t(Command.t()) | :instance_not_found}
  def create(
        %TransactionEventMap{action: :create_transaction, payload: %{status: :pending}} = attrs
      ) do
    case Multi.new()
         |> Multi.one(
           :instance,
           InstanceStoreHelper.build_get_id_by_address(attrs.instance_address)
         )
         |> Multi.insert(:command, fn %{instance: id} ->
           build_create(attrs, id)
         end)
         |> Multi.insert(:pending_transaction_lookup, fn %{
                                                           command: %{id: cid, event_map: em},
                                                           instance: iid
                                                         } ->
           attrs = %{
             command_id: cid,
             source: em.source,
             source_idempk: em.source_idempk,
             instance_id: iid
           }

           PendingTransactionLookup.upsert_changeset(%PendingTransactionLookup{}, attrs)
         end)
         |> Repo.transaction() do
      {:ok, %{command: event}} ->
        {:ok, event}

      {:error, :pending_transaction_lookup, _, _} ->
        {:error, :pending_transaction_idempotency_violation}

      {:error, :command, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def create(%{instance_address: address} = attrs) do
    case Multi.new()
         |> Multi.one(:instance, InstanceStoreHelper.build_get_id_by_address(address))
         |> Multi.insert(:event, fn %{instance: id} ->
           build_create(attrs, id)
         end)
         |> Repo.transaction() do
      {:ok, %{event: event}} -> {:ok, event}
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
    - List of Command structs, ordered by insertion time descending

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
    iex> TransactionStore.create(instance.address, create_attrs, "unique_id_123")
    iex> length(CommandStore.list_all_for_instance_id(instance.id))
    3
    iex> # test pagination
    iex> length(CommandStore.list_all_for_instance_id(instance.id, 2, 2))
    1

  """
  @spec list_all_for_instance_id(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Command.t())
  def list_all_for_instance_id(instance_id, page \\ 1, per_page \\ 40) do
    from(e in Command,
      where: e.instance_id == ^instance_id,
      order_by: [desc: e.inserted_at],
      select: e
    )
    |> paginate(page, per_page)
    |> preload([:command_queue_item, :transaction])
    |> Repo.all()
  end

  @doc """
  Lists all events associated with a specific transaction.

  ## Parameters
    - `transaction_id`: ID of the transaction to list events for

  ## Returns
    - List of Command structs, ordered by insertion time descending

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
    iex> TransactionStore.update(instance.address, id, %{status: :posted}, "unique_id_123")
    iex> length(CommandStore.list_all_for_transaction_id(id))
    2
  """
  @spec list_all_for_transaction_id(Ecto.UUID.t()) :: list(Command.t())
  def list_all_for_transaction_id(transaction_id) do
    base_transaction_query(transaction_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end
end
