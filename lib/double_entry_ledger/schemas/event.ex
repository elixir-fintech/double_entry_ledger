defmodule DoubleEntryLedger.Event do
  @moduledoc """
  Defines and manages events in the Double Entry Ledger system.

  This module provides the Event schema, which represents a request to create or update a
  transaction in the ledger. Events serve as an audit trail and queue mechanism for transaction
  processing, allowing for asynchronous handling, retries, and idempotency.
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{
    Transaction,
    Instance,
    Account,
    EventTransactionLink,
    EventAccountLink,
    EventQueueItem
  }

  alias DoubleEntryLedger.Event.EventMap

  alias __MODULE__, as: Event

  @typedoc """
  Represents an event in the Double Entry Ledger system.

  An event encapsulates a request to create or update a transaction, along with
  metadata about the processing state, source, and queue management information.

  ## Fields

  * `id`: UUID primary key
  * `event_map`: map containing the event payload
  * `instance`: Association to the ledger instance
  * `instance_id`: Foreign key to the ledger instance
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
  @type t :: %Event{
          id: Ecto.UUID.t() | nil,
          event_map: map() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          event_transaction_links: [EventTransactionLink.t()] | Ecto.Association.NotLoaded.t(),
          transactions: [Transaction.t()] | Ecto.Association.NotLoaded.t(),
          event_account_link: EventAccountLink.t() | Ecto.Association.NotLoaded.t(),
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          event_queue_item: EventQueueItem.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @derive {Jason.Encoder, only: [:id, :event_map, :event_queue_item]}

  schema "events" do
    field(:event_map, EventMap, skip_default_validation: true)

    belongs_to(:instance, Instance, type: Ecto.UUID)
    has_many(:event_transaction_links, EventTransactionLink)
    many_to_many(:transactions, Transaction, join_through: EventTransactionLink)
    has_one(:event_queue_item, DoubleEntryLedger.EventQueueItem)
    has_one(:event_account_link, DoubleEntryLedger.EventAccountLink)
    has_one(:account, through: [:event_account_link, :account])

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and creating/updating an Event.

  This function builds an Ecto changeset for an event with appropriate validations
  and handling based on the action type and transaction data provided.

  ## Parameters

  * `event` - The Event struct to create a changeset for
  * `attrs` - Map of attributes to apply to the event

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Create event changeset
      iex> event_map = %{
      ...>   action: :create_transaction,
      ...>   source: "api",
      ...>   source_idempk: "order-123",
      ...>   instance_address: "instance1",
      ...>   payload: %{status: :pending, entries: [
      ...>     %{account_address: "account1", amount: 100, currency: :USD},
      ...>     %{account_address: "account2", amount: 100, currency: :USD}
      ...>   ]}
      ...> }
      ...> attrs = %{instance_id: Ecto.UUID.generate(), event_map: event_map}
      iex> changeset = Event.changeset(%Event{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec changeset(Event.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> base_changeset(attrs)
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
  @spec processing_start_changeset(Event.t(), String.t(), non_neg_integer()) :: Ecto.Changeset.t()
  def processing_start_changeset(
        %{event_queue_item: event_queue_item} = event,
        processor_id,
        retry_count
      ) do
    event_queue_changeset =
      event_queue_item
      |> EventQueueItem.processing_start_changeset(processor_id, retry_count)

    event
    |> change(%{})
    |> put_assoc(:event_queue_item, event_queue_changeset)
  end

  @spec base_changeset(Event.t() | Ecto.Changeset.t(Event.t()), map()) :: Ecto.Changeset.t()
  defp base_changeset(event, attrs) do
    attrs = Map.put_new(attrs, :event_queue_item, %{})

    event
    |> cast(attrs, [
      :instance_id,
      :event_map
    ])
    |> validate_required([:instance_id, :event_map])
    |> cast_assoc(:event_queue_item, with: &EventQueueItem.changeset/2, required: true)
    #|> validate_event_map(attrs)
  end

  #defp validate_event_map(changeset, attrs) do
    #case Map.get(attrs, :event_map) || Map.get(attrs, "event_map") do
      #%{} = event_map ->
        #with {:ok, mod} <- action_to_mod(event_map),
          #inner_cs <- mod.changeset(struct(mod), event_map),
          #false <- inner_cs.valid? do
            #Map.put(changeset, :event_map_changeset, inner_cs)
        #else
          #_ -> changeset
        #end
      #_ -> changeset
    #end
  #end
end
