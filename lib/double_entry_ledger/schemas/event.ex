defmodule DoubleEntryLedger.Event do
  @moduledoc """
  Defines and manages events in the Double Entry Ledger system.

  This module provides the Event schema, which represents a request to create or update a
  transaction in the ledger. Events serve as an audit trail and queue mechanism for transaction
  processing, allowing for asynchronous handling, retries, and idempotency.

  ## Key Concepts

  * **Event Processing**: Events progress through states (:pending → :processing → :processed/:failed)
  * **Idempotency**: Idempotency is enforced using a combination of `action`, `source`, `source_idempk` and `update_idempk`. More details
    are in the `EventMap` module.
  * **Transaction Data**: Each event contains embedded transaction_data describing the requested changes
  * **Queue Management**: Fields track processing attempts, retries, and completion status

  ## Event States

  * `:pending` - Newly created, not yet processed
  * `:processing` - Currently being processed by a worker
  * `:processed` - Successfully completed
  * `:failed` - Processing failed with errors
  * `:occ_timeout` - Failed due to optimistic concurrency control timeout

  ## Event Actions

  * `:create` - Request to create a new transaction
  * `:update` - Request to update an existing transaction (requires update_idempk)

  ## Processing Flow

  1. Event is created with :pending status
  2. Worker claims event and updates status to :processing
  3. Worker processes the event and creates/updates a transaction
  4. Event is updated to :processed or :failed with results
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{Transaction, Instance, EventTransactionLink, EventQueueItem}
  alias DoubleEntryLedger.Event.TransactionData

  @states [:pending, :processed, :failed, :occ_timeout, :processing, :dead_letter]
  @actions [:create, :update]
  @type state ::
          unquote(
            Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )
  @type action ::
          unquote(
            Enum.reduce(@actions, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )

  alias __MODULE__, as: Event

  @typedoc """
  Represents an event in the Double Entry Ledger system.

  An event encapsulates a request to create or update a transaction, along with
  metadata about the processing state, source, and queue management information.

  ## Fields

  * `id`: UUID primary key
  * `status`: Current processing state (:pending, :processing, :processed, :failed, :occ_timeout, :dead_letter)
  * `action`: The action type (:create or :update)
  * `source`: Identifier for the system that originated the event
  * `source_data`: Arbitrary JSON data from the source system
  * `source_idempk`: Idempotency key from source system
  * `update_idempk`: Additional idempotency key for update operations
  * `occ_retry_count`: Counter for optimistic concurrency control retries
  * `processed_at`: When the event was fully processed
  * `transaction_data`: Embedded struct with transaction changes to apply
  * `instance`: Association to the ledger instance
  * `instance_id`: Foreign key to the ledger instance
  * `errors`: Array of error maps if processing failed
  * `processor_id`: ID of the worker processing this event
  * `processor_version`: Version for optimistic locking during processing
  * `processing_started_at`: When processing began
  * `processing_completed_at`: When processing finished
  * `retry_count`: Number of processing attempts
  * `next_retry_after`: Timestamp for next retry attempt
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
  @type t :: %Event{
          id: Ecto.UUID.t() | nil,
          status: state() | nil,
          action: action() | nil,
          source: String.t() | nil,
          source_data: map() | nil,
          source_idempk: String.t() | nil,
          update_idempk: String.t() | nil,
          transaction_data: TransactionData.t() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          event_transaction_links: [EventTransactionLink.t()] | Ecto.Association.NotLoaded.t(),
          transactions: [Transaction.t()] | Ecto.Association.NotLoaded.t(),
          event_queue_item: EventQueueItem.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          # queue related fields
        }

  schema "events" do
    field(:status, Ecto.Enum, values: @states, default: :pending)
    field(:action, Ecto.Enum, values: @actions)
    field(:source, :string)
    field(:source_data, :map, default: %{})
    field(:source_idempk, :string)
    field(:update_idempk, :string)

    belongs_to(:instance, Instance, type: Ecto.UUID)
    embeds_one(:transaction_data, DoubleEntryLedger.Event.TransactionData)
    has_many(:event_transaction_links, EventTransactionLink)
    has_many(:transactions, through: [:event_transaction_links, :transaction])
    has_one(:event_queue_item, DoubleEntryLedger.EventQueueItem)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns a list of available event actions.

  ## Returns

  * A list of atoms representing the valid actions (:create, :update)

  ## Examples

      iex> DoubleEntryLedger.Event.actions()
      [:create, :update]
  """
  @spec actions() :: [action()]
  def actions(), do: @actions

  @doc """
  Creates a changeset for validating and creating/updating an Event.

  This function builds an Ecto changeset for an event with appropriate validations
  and handling based on the action type and transaction data provided.

  ## Parameters

  * `event` - The Event struct to create a changeset for
  * `attrs` - Map of attributes to apply to the event

  ## Special Handling

  * For `:update` actions with `:pending` transaction status: Uses standard TransactionData changeset
  * For other `:update` actions: Uses the special update_event_changeset for TransactionData
  * For `:create` actions: Uses standard TransactionData changeset

  ## Validations

  * Required fields: `:action`, `:source`, `:source_idempk`, `:instance_id`
  * For updates: also requires `:update_idempk`
  * Enforces unique constraints for idempotency

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Create event changeset
      iex> attrs = %{
      ...>   action: :create,
      ...>   source: "api",
      ...>   source_idempk: "order-123",
      ...>   instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   transaction_data: %{status: :pending, entries: [
      ...>     %{account_id: "550e8400-e29b-41d4-a716-446655440000", type: :debit, amount: 100, currency: :USD},
      ...>     %{account_id: "650e8400-e29b-41d4-a716-446655440000", type: :credit, amount: 100, currency: :USD}
      ...>   ]}
      ...> }
      iex> changeset = Event.changeset(%Event{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec changeset(Event.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, %{action: :update, transaction_data: %{status: :pending}} = attrs) do
    event
    |> base_changeset(attrs)
    |> update_changeset()
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  def changeset(event, %{action: :update} = attrs) do
    event
    |> base_changeset(attrs)
    |> update_changeset()
    |> cast_embed(:transaction_data,
      with: &TransactionData.update_event_changeset/2,
      required: true
    )
  end

  def changeset(event, attrs) do
    event
    |> base_changeset(attrs)
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  @doc """
  Creates a changeset for marking an event as being processed.

  This function prepares a changeset that updates an event to the :processing state,
  assigns a processor, and updates processing metadata such as start time and retry count.

  ## Parameters

  * `event` - The Event struct to update
  * `processor_id` - String identifier for the processor handling the event

  ## Returns

  * An Ecto.Changeset with processing status updates and optimistic locking

  ## Fields Updated

  * `status`: Set to :processing
  * `processor_id`: Set to the provided processor_id
  * `processing_started_at`: Set to current UTC datetime
  * `processing_completed_at`: Set to nil
  * `retry_count`: Incremented by 1
  * `next_retry_after`: Set to nil
  * `processor_version`: Used for optimistic locking

  """
  @spec processing_start_changeset(Event.t(), String.t()) :: Ecto.Changeset.t()
  def processing_start_changeset(%{event_queue_item: event_queue_item} = event, processor_id) do
    event_queue_changeset =
      event_queue_item
      |> EventQueueItem.processing_start_changeset(processor_id)

    event
    |> change(%{})
    |> put_assoc(:event_queue_item, event_queue_changeset)
  end

  @doc """
  Builds a map of trace metadata for logging from an event.

  This function extracts key fields from the given `Event` struct to provide
  consistent, structured metadata for logging and tracing purposes. The returned map
  includes the event's ID, status, action, source, and a composite trace ID.

  ## Parameters

    - `event`: The `Event` struct to extract trace information from.

  ## Returns

    - A map containing trace metadata for the event.
  """
  @spec log_trace(Event.t()) :: map()
  def log_trace(%{event_queue_item: event_queue_item} = event) do
    %{
      event_id: event.id,
      event_status: event_queue_item.status,
      event_action: event.action,
      event_source: event.source,
      event_trace_id:
        [event.source, event.source_idempk, event.update_idempk]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @doc """
  Builds a map of trace metadata for logging from an event and a transaction or and error.

  This function extends `log_trace/1` by also including the transaction ID
  when a `Transaction` struct is provided.

  ## Parameters

    - `event`: The `Event` struct to extract trace information from.
    - `transaction` | `error`: The `Transaction` struct to extract the transaction ID from, or the error value to display

  ## Returns

    - A map containing trace metadata for the event and transaction or error
  """
  @spec log_trace(Event.t(), Transaction.t() | any()) :: map()
  def log_trace(event, %Transaction{} = transaction) do
    Map.put(
      log_trace(event),
      :transaction_id,
      transaction.id
    )
  end

  def log_trace(event, error) do
    Map.put(
      log_trace(event),
      :error,
      inspect(error, label: "Error")
    )
  end

  @spec base_changeset(Event.t(), map()) :: Ecto.Changeset.t()
  defp base_changeset(event, attrs) do
    attrs = Map.put_new(attrs, :event_queue_item, %{})

    event
    |> cast(attrs, [:action, :source, :source_data, :source_idempk, :instance_id, :update_idempk])
    |> validate_required([:action, :source, :source_idempk, :instance_id])
    |> validate_inclusion(:action, @actions)
    |> cast_assoc(:event_queue_item, with: &EventQueueItem.changeset/2, required: true)
    |> unique_constraint(:source_idempk,
      name: "unique_instance_source_source_idempk",
      message: "already exists for this instance"
    )
  end

  @spec update_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp update_changeset(changeset) do
    changeset
    |> validate_required([:update_idempk])
    |> unique_constraint(:update_idempk,
      name: "unique_instance_source_source_idempk_update_idempk",
      message: "already exists for this source_idempk"
    )
  end
end
