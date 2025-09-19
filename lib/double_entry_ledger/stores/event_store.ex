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

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.{Repo, Event, InstanceStoreHelper}
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

  This function creates a TransactionEventMap from the parameters, then processes it through
  the EventWorker to create both an event record in the EventStore and creates the necessary projections.

  If the processing fails, it will return an error tuple with details about the failure. The event is saved to the EventStore and then retried later.

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
  to validate and process events but avoid storing error states in the EventQueueItem records.
  Using this version means that if processing fails, the event will not be saved,
  allowing for custom error handling or debugging without polluting the event store.

  ## Supported Actions

  Same as `process_from_event_params/1` - supports both transaction and account actions.

  ## Parameters
    - `event_params`: Map containing event parameters including action and payload data

  ## Returns
    - `{:ok, transaction, event}`: If a transaction event was successfully processed
    - `{:ok, account, event}`: If an account event was successfully processed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons
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
  """
  @spec list_all_for_instance(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Event.t())
  def list_all_for_instance(instance_id, page \\ 1, per_page \\ 40) do
    offset = (page - 1) * per_page

    from(e in Event,
      where: e.instance_id == ^instance_id,
      order_by: [desc: e.inserted_at],
      limit: ^per_page,
      offset: ^offset,
      select: e
    )
    |> preload([:event_queue_item, :transactions, :account])
    |> Repo.all()
  end

  @doc """
  Lists all events associated with a specific transaction.

  ## Parameters
    - `transaction_id`: ID of the transaction to list events for

  ## Returns
    - List of Event structs, ordered by insertion time descending
  """
  @spec list_all_for_transaction(Ecto.UUID.t()) :: list(Event.t())
  def list_all_for_transaction(transaction_id) do
    base_transaction_query(transaction_id)
    |> order_by([desc: :inserted_at])
    |> Repo.all()
  end

  @spec get_create_transaction_event(Ecto.UUID.t()) :: Event.t()
  def get_create_transaction_event(transaction_id) do
    base_transaction_query(transaction_id)
    |> join(:inner, [e], eqi in assoc(e, :event_queue_item))
    |> where([e], e.action == :create_transaction)
    |> where([_,_, eqi], eqi.status == :processed)
    |> order_by([asc: :inserted_at])
    |> Repo.one()
  end

  @doc """
  Lists all events associated with a specific account.

  ## Parameters
    - `account_id`: ID of the account to list events for

  ## Returns
    - List of Event structs, ordered by insertion time descending
  """
  @spec list_all_for_account(Ecto.UUID.t()) :: list(Event.t())
  def list_all_for_account(account_id) do
    base_account_query(account_id)
    |> order_by([desc: :inserted_at])
    |> Repo.all()
  end

  @spec get_create_account_event(Ecto.UUID.t()) :: Event.t()
  def get_create_account_event(account_id) do
    base_account_query(account_id)
    |> join(:inner, [e], eqi in assoc(e, :event_queue_item))
    |> where([e], e.action == :create_account)
    |> where([_,_, eqi], eqi.status == :processed)
    |> order_by([asc: :inserted_at])
    |> Repo.one()
  end

  @doc """
  Creates a new event record after a processing failure, preserving error information.

  This function is used to persist an event that failed to process, including its error details,
  retry count, and status. It is typically called when an event could not be saved or processed
  successfully, allowing for later inspection or retry.

  ## Parameters
    - `event`: The original `%Event{}` struct that failed
    - `errors`: A list of error messages or error maps to attach to the event
    - `retries`: The number of retry attempts that have been made
    - `status`: The new status for the event (e.g., `:failed`, `:occ_timeout`)

  ## Returns
    - `{:ok, %Event{}}` if the event was successfully created
    - `{:error, %Ecto.Changeset{}}` if validation or insertion failed
  """
  @spec create_event_after_failure(Event.t(), list(), integer(), atom()) ::
          {:ok, Event.t()} | {:error, Changeset.t()}
  def create_event_after_failure(event, errors, retries, status) do
    event
    |> Changeset.change(errors: errors, status: status, occ_retry_count: retries)
    |> Repo.insert()
  end

  @spec base_transaction_query(Ecto.UUID.t()) :: Ecto.Query.t()
  defp base_transaction_query(transaction_id) do
    from(e in Event,
      join: evt in assoc(e, :event_transaction_links),
      where: evt.transaction_id == ^transaction_id,
      select: e
    )
    |> preload([:event_queue_item, :account, transactions: :entries])
  end

  @spec base_account_query(Ecto.UUID.t()) :: Ecto.Query.t()
  defp base_account_query(account_id) do
    from(e in Event,
      join: evt in assoc(e, :event_account_link),
      where: evt.account_id == ^account_id,
      select: e
    )
    |> preload([:event_queue_item, :transactions, :account])
  end
end
