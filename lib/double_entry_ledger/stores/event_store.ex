defmodule DoubleEntryLedger.EventStore do
  @moduledoc """
  Provides functions for managing events in the double-entry ledger system.

  This module serves as the primary interface for all event-related operations, including
  creating, retrieving, processing, and querying events. It manages the complete lifecycle
  of events from creation through processing to completion or failure.

  ## Key Functionality

    * **Event Management**: Create, retrieve, and track events.
    * **Event Processing**: Claim events for processing, mark events as processed or failed.
    * **Event Queries**: Find events by instance, transaction ID, or other criteria.
    * **Error Handling**: Track and manage errors that occur during event processing.

  ## Usage Examples

  ### Creating and processing a new event

      {:ok, transaction, event} = DoubleEntryLedger.EventStore.process_from_event_params(%{
        instance_id: instance.id,
        action: :create,
        transaction_data: %{
          entries: [
            %{account_id: cash_account.id, amount: 100_00, type: :debit},
            %{account_id: revenue_account.id, amount: 100_00, type: :credit}
          ],
          description: "Cash sale",
          metadata: %{reference_number: "INV-001"}
        }
      })

  ### Retrieving events for an instance

      events = DoubleEntryLedger.EventStore.list_all_for_instance(instance.id)

  ### Retrieving events for a transaction

      events = DoubleEntryLedger.EventStore.list_all_for_transaction(transaction.id)

  ### Manually processing an event

      {:ok, event} = DoubleEntryLedger.EventStore.claim_event_for_processing(event.id, "worker-1")
      # Process event logic here
      {:ok, _updated_event} = DoubleEntryLedger.EventStore.mark_as_processed(event, transaction.id)

  ## Implementation Notes

  - The module implements optimistic concurrency control for event claiming and processing,
    ensuring that events are processed exactly once even in high-concurrency environments.
  - All queries are paginated and ordered by insertion time descending for efficient retrieval.
  - Error handling is explicit, with clear return values for all failure modes.
  """
  import Ecto.Query
  import DoubleEntryLedger.EventStoreHelper

  alias Ecto.Changeset
  alias DoubleEntryLedger.{Repo, Event}
  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.EventWorker

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
    |> preload([:event_queue_item, :transactions])
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
  @spec create(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    build_create(attrs)
    |> Repo.insert()
  end

  @doc """
  Processes an event from provided parameters, handling the entire workflow.

  This function creates an EventMap from the parameters, then processes it through
  the EventWorker to create both an event record and its associated transaction.

  ## Parameters
    - `event_params`: Map containing event parameters including action and transaction data

  ## Returns
    - `{:ok, transaction, event}`: If the event was successfully processed
    - `{:error, event}`: If the event processing failed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons
  """
  @spec process_from_event_params(map()) ::
    EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_from_event_params(event_params) do
    case EventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end

  @spec process_from_event_params_no_save_on_error(map()) ::
    EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_from_event_params_no_save_on_error(event_params) do
    case EventMap.create(event_params) do
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
    |> preload([:event_queue_item, :transactions])
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
    from(e in Event,
      join: evt in assoc(e, :event_transaction_links),
      where: evt.transaction_id == ^transaction_id,
      select: e,
      order_by: [desc: e.inserted_at]
    )
    |> preload([:event_queue_item, :transactions])
    |> Repo.all()
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
end
