defmodule DoubleEntryLedger.EventStore do
  @moduledoc """
  Provides functions for managing events in the double-entry ledger system.

  This module serves as the primary interface for all event-related operations, including
  creating, retrieving, processing, and querying events. It manages the complete lifecycle
  of events from creation through processing to completion or failure.

  ## Key Functionality

  * **Event Management**: Create, retrieve, and track events
  * **Event Processing**: Claim events for processing, mark events as processed or failed
  * **Event Queries**: Find events by instance, transaction ID, or other criteria
  * **Error Handling**: Track and manage errors that occur during event processing

  ## Usage Examples

  Creating and processing a new event:

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

  Retrieving events for an instance:

      events = DoubleEntryLedger.EventStore.list_all_for_instance(instance.id)

  Retrieving events for a transaction:

      events = DoubleEntryLedger.EventStore.list_all_for_transaction(transaction.id)

  Manually processing an event:

      {:ok, event} = DoubleEntryLedger.EventStore.claim_event_for_processing(event.id, "worker-1")
      # Process event logic here
      {:ok, _updated_event} = DoubleEntryLedger.EventStore.mark_as_processed(event, transaction.id)

  ## Implementation Notes

  The module implements optimistic concurrency control for event claiming and processing,
  ensuring that events are processed exactly once even in high-concurrency environments.
  """
  import Ecto.Query
  import DoubleEntryLedger.EventStoreHelper

  alias Ecto.Changeset
  alias DoubleEntryLedger.{Repo, Event, Transaction}
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
    Repo.get(Event, id)
  end

  @doc """
  Claims an event for processing by marking it as being processed by a specific processor.

  This function implements optimistic concurrency control to ensure that only one processor
  can claim an event at a time. It only allows claiming events with status :pending or :occ_timeout.

  ## Parameters
    - `id`: The UUID of the event to claim
    - `processor_id`: A string identifier for the processor claiming the event (defaults to "manual")
    - `repo`: The Ecto repository to use (defaults to Repo)

  ## Returns
    - `{:ok, event}`: If the event was successfully claimed
    - `{:error, :event_not_found}`: If no event with the given ID exists
    - `{:error, :event_not_claimable}`: If the event cannot be claimed (wrong status or claimed by another processor)
  """
  @spec claim_event_for_processing(Ecto.UUID.t(), String.t(), Ecto.Repo.t()) ::
          {:ok, Event.t()} | {:error, atom()}
  def claim_event_for_processing(id, processor_id \\ "manual", repo \\ Repo) do
    case get_by_id(id) do
      nil ->
        {:error, :event_not_found}

      event ->
        if event.status in [:pending, :occ_timeout] do
          try do
            Event.processing_start_changeset(event, processor_id)
            |> repo.update()
          rescue
            Ecto.StaleEntryError ->
              {:error, :event_not_claimable}
          end
        else
          {:error, :event_not_claimable}
        end
    end
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
          {:ok, Transaction.t(), Event.t()}
          | {:error, Event.t() | Ecto.Changeset.t() | String.t()}
  def process_from_event_params(event_params) do
    case EventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event(event_map)

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

    Repo.all(
      from(e in Event,
        where: e.instance_id == ^instance_id,
        order_by: [desc: e.inserted_at],
        limit: ^per_page,
        offset: ^offset,
        select: e
      )
    )
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
    Repo.all(
      from(e in Event,
        where: e.processed_transaction_id == ^transaction_id,
        select: e,
        order_by: [desc: e.inserted_at]
      )
    )
  end

  @doc """
  Creates a new event after a processing failure, preserving error information.

  ## Parameters
    - `event`: The original event that failed
    - `errors`: List of error messages or maps
    - `retries`: Number of retries that have been attempted
    - `status`: New status for the event (typically :failed or :occ_timeout)

  ## Returns
    - `{:ok, event}`: If the new event was successfully created
    - `{:error, changeset}`: If event creation failed
  """
  @spec create_event_after_failure(Event.t(), list(), integer(), atom()) ::
          {:ok, Event.t()} | {:error, Changeset.t()}
  def create_event_after_failure(event, errors, retries, status) do
    event
    |> Changeset.change(errors: errors, status: status, occ_retry_count: retries)
    |> Repo.insert()
  end

  @doc """
  Marks an event as failed with the provided error reason.

  ## Parameters
    - `event`: The event to mark as failed
    - `reason`: Error message or reason for failure

  ## Returns
    - `{:ok, event}`: If the event was successfully updated
    - `{:error, changeset}`: If the update failed
  """
  @spec mark_as_failed(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_failed(event, reason) do
    event
    |> build_add_error(reason)
    |> Changeset.change(status: :failed)
    |> Repo.update()
  end

  @doc """
  Adds an error to the event's error list without changing its status.

  ## Parameters
    - `event`: The event to add an error to
    - `error`: Error message or data to add

  ## Returns
    - `{:ok, event}`: If the event was successfully updated
    - `{:error, changeset}`: If the update failed
  """
  @spec add_error(Event.t(), any()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def add_error(event, error) do
    event
    |> build_add_error(error)
    |> Repo.update()
  end
end
