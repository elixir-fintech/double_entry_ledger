defmodule DoubleEntryLedger.Event do
  @moduledoc """
  Defines and manages events in the Double Entry Ledger system.

  This module provides the Event schema, which represents a request to create or update a
  transaction in the ledger. Events serve as an audit trail and queue mechanism for transaction
  processing, allowing for asynchronous handling, retries, and idempotency.

  ## Key Concepts

  * **Event Processing**: Events progress through states (:pending → :processing → :processed/:failed)
  * **Idempotency**: Idempotency is enforced using a combination of `action`, `source`, `source_idempk` and `update_idempk`. More details
    are in the `TransactionEventMap` module.
  * **Transaction Data**: Each event contains embedded payload describing the requested changes
  * **Queue Management**: Fields track processing attempts, retries, and completion status

  ## Event States

  * `:pending` - Newly created, not yet processed
  * `:processing` - Currently being processed by a worker
  * `:processed` - Successfully completed
  * `:failed` - Processing failed with errors
  * `:occ_timeout` - Failed due to optimistic concurrency control timeout

  ## Event Actions

  * `:create_transaction` - Request to create a new transaction
  * `:update_transaction` - Request to update an existing transaction (requires update_idempk)

  ## Processing Flow

  1. Event is created with :pending status
  2. Worker claims event and updates status to :processing
  3. Worker processes the event and creates/updates a transaction
  4. Event is updated to :processed or :failed with results
  """

  use DoubleEntryLedger.BaseSchema

  #import DoubleEntryLedger.Event.Helper, only: [action_to_mod: 1]

  alias DoubleEntryLedger.{
    Transaction,
    Instance,
    Account,
    EventTransactionLink,
    EventAccountLink,
    EventQueueItem
  }

  alias DoubleEntryLedger.Event.EventMap

  @transaction_actions [:create_transaction, :update_transaction]
  @account_actions [:create_account, :update_account]
  @actions @transaction_actions ++ @account_actions

  @type transaction_action ::
          unquote(
            Enum.reduce(@transaction_actions, fn state, acc ->
              quote do: unquote(state) | unquote(acc)
            end)
          )

  @type account_action ::
          unquote(
            Enum.reduce(@account_actions, fn state, acc ->
              quote do: unquote(state) | unquote(acc)
            end)
          )

  @type action :: transaction_action() | account_action()

  alias __MODULE__, as: Event

  @typedoc """
  Represents an event in the Double Entry Ledger system.

  An event encapsulates a request to create or update a transaction, along with
  metadata about the processing state, source, and queue management information.

  ## Fields

  * `id`: UUID primary key
  * `action`: The action type (:create_transaction or :update_transaction)
  * `source`: Identifier for the system that originated the event
  * `source_idempk`: Idempotency key from source system
  * `update_idempk`: Additional idempotency key for update operations
  * `event_map`: map containing the event payload
  * `instance`: Association to the ledger instance
  * `instance_id`: Foreign key to the ledger instance
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
  @type t :: %Event{
          id: Ecto.UUID.t() | nil,
          action: action() | nil,
          source: String.t() | nil,
          source_idempk: String.t() | nil,
          update_idempk: String.t() | nil,
          update_source: String.t() | nil,
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
    field(:action, Ecto.Enum, values: @actions)
    field(:source, :string)
    field(:source_idempk, :string)
    field(:update_idempk, :string)
    field(:update_source, :string)
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
  Returns a list of available event actions.

  ## Returns

  * A list of atoms representing the valid actions (:create_transaction, :update_transaction)

  ## Examples

      iex> DoubleEntryLedger.Event.actions()
      [:create_transaction, :update_transaction, :create_account, :update_account]
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

  * For `:update_transaction` actions with `:pending` transaction status: Uses standard TransactionData changeset
  * For other `:update_transaction` actions: Uses the special update_event_changeset for TransactionData
  * For `:create_transaction` actions: Uses standard TransactionData changeset

  ## Validations

  * Required fields: `:action`, `:source`, `:source_idempk`, `:instance_id`
  * For updates: also requires `:update_idempk`
  * Enforces unique constraints for idempotency

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Create event changeset
      iex> event_map = %{
      ...>   action: :create_transaction,
      ...>   source: "api",
      ...>   source_idempk: "order-123",
      ...>   instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   instance_address: "instance1",
      ...>   payload: %{status: :pending, entries: [
      ...>     %{account_address: "account1", amount: 100, currency: :USD},
      ...>     %{account_address: "account2", amount: 100, currency: :USD}
      ...>   ]}
      ...> }
      ...> attrs = Map.put(event_map, :event_map, event_map)
      iex> changeset = Event.changeset(%Event{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec changeset(Event.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, %{event_map: %{action: :update_transaction}} = attrs) do
    event
    |> update_changeset(attrs)
  end

  def changeset(event, %{event_map: %{action: :update_account}} = attrs) do
    event
    |> update_changeset(attrs)
  end

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
      :action,
      :source,
      :source_idempk,
      :instance_id,
      :event_map
    ])
    |> validate_required([:action, :source, :source_idempk, :instance_id, :event_map])
    |> validate_inclusion(:action, @actions)
    |> cast_assoc(:event_queue_item, with: &EventQueueItem.changeset/2, required: true)
    #|> validate_event_map(attrs)
  end

  @spec update_changeset(Event.t(), map()) :: Ecto.Changeset.t()
  defp update_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:update_idempk, :update_source])
    |> validate_required([:update_idempk])
    |> base_changeset(attrs)
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
