defmodule DoubleEntryLedger.Event.TransactionEventMap do
  @moduledoc """
  Defines the TransactionEventMap schema for representing event data in the Double Entry Ledger system.

  This module provides an embedded schema and related functions for creating and validating
  event maps, which serve as the primary data structure for transaction creation and updates.
  TransactionEventMap represents the pre-persistence state of an Event, containing all necessary data
  to either create a new transaction or update an existing one.

  ## Structure

  TransactionEventMap contains the following fields:

  * `action`: The type of action to perform (:create_transaction or :update_transaction)
  * `instance_id`: UUID of the ledger instance this event belongs to
  * `source`: Identifier of the external system generating the event
  * `source_data`: Optional map containing additional metadata from the source system
  * `source_idempk`: Primary identifier from the source system (used for idempotency)
  * `update_idempk`: Unique identifier for update operations, enabling multiple distinct updates
     to the same original transaction while maintaining idempotency
  * `transaction_data`: Embedded TransactionData containing entries and transaction details

  ## Key Functions

  * `create/1`: Creates and validates an TransactionEventMap from a map of attributes
  * `changeset/2`: Builds a changeset for validating TransactionEventMap data
  * `to_map/1`: Converts an TransactionEventMap struct to a plain map representation
  * `log_trace/1,2`: Builds a map of trace metadata for logging from an TransactionEventMap

  ## Implementation Details

  ### Idempotency Enforcement

  The system enforces idempotency differently depending on the action type:

  * **Create actions**: Idempotency is enforced using a combination of `:create_transaction` action value,
    `source` and the `source_idempk`. This ensures the same external transaction is never created twice.

  * **Update actions**: Idempotency uses a combination of `:update_transaction` action value, the original `source`
    and `source_idempk` (identifying which create action to update), and the `update_idempk`
    (identifying this specific update). This allows multiple distinct updates to the same
    original transaction.

  Both combinations are protected by unique indexes in the database to prevent duplicate processing.
  The TransactionEventMap schema itself does not enforce these constraints, as it is not persisted directly.
  Instead, the Event schema handles this at the database level.
  Only transactions with status `:pending` can be updated.

  ## Workflow Integration

  TransactionEventMaps are typically created from external input data, validated, and then processed
  by the EventWorker system to create or update transactions in the ledger.

  ## Examples

  Creating an TransactionEventMap for a new transaction:

      TransactionEventMap.create(%{
        action: "create_transaction",
        instance_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db9",
        source: "accounting_system",
        source_idempk: "invoice_123",
        transaction_data: %{
          status: "pending",
          entries: [
            %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: "USD"},
            %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: "USD"}
          ]
        }
      })

  Creating an TransactionEventMap for updating an existing transaction:

      TransactionEventMap.create(%{
        action: "update",
        instance_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db9",
        source: "accounting_system",
        source_idempk: "invoice_123",
        update_idempk: "invoice_123_update_1",
        transaction_data: %{
          status: "posted",
          description: "Updated invoice payment"
        }
      })
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Event.TransactionData

  alias __MODULE__, as: TransactionEventMap

  @update_actions [:update_transaction, "update_transaction"]

  @typedoc """
  Represents an TransactionEventMap structure for transaction creation or updates.

  This is the primary data structure used for creating or updating transactions in the ledger system
  before they are persisted to the database.

  ## Fields

  * `action`: The operation type (:create_transaction or :update_transaction)
  * `instance_id`: UUID of the ledger instance this event belongs to
  * `source`: Identifier of the external system generating the event
  * `source_data`: Optional metadata from the source system
  * `source_idempk`: Primary identifier used for idempotency
  * `update_idempk`: Unique identifier for update operations to maintain idempotency
  * `transaction_data`: The embedded transaction data structure
  """
  @type t :: %TransactionEventMap{
          action: Event.action(),
          instance_id: Ecto.UUID.t(),
          source: String.t(),
          source_data: map() | nil,
          source_idempk: String.t(),
          update_idempk: String.t() | nil,
          transaction_data: TransactionData.t()
        }

  @derive {Jason.Encoder,
           only: [
             :action,
             :instance_id,
             :source,
             :source_data,
             :source_idempk,
             :update_idempk,
             :transaction_data
           ]}

  @primary_key false
  embedded_schema do
    field(:action, Ecto.Enum, values: Event.actions())
    field(:instance_id, :string)
    field(:source, :string)
    field(:source_data, :map, default: %{})
    field(:source_idempk, :string)
    field(:update_idempk, :string)
    embeds_one(:transaction_data, TransactionData, on_replace: :delete)
  end

  @doc """
  Builds a validated TransactionEventMap or returns a changeset with errors.

  ## Parameters
    - `attrs`: A map containing the event data.

  ## Returns
    - `{:ok, event_map}` on success.
    - `{:error, changeset}` on failure.

  ## Example

    iex> alias DoubleEntryLedger.Event.TransactionEventMap
    iex> {:ok, em} = TransactionEventMap.create(%{action: "create_transaction", instance_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db9", source: "source", source_idempk: "source_idempk",
    ...>   transaction_data: %{status: "pending", entries: [
    ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: "USD"},
    ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: "USD"}
    ...>   ]}})
    iex> is_struct(em, TransactionEventMap)

  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %TransactionEventMap{}
    |> changeset(attrs)
    |> Changeset.apply_action(:insert)
  end

  @doc """
  Creates a changeset for validating TransactionEventMap attributes.

  This function builds an Ecto changeset that validates the required fields and structure
  of an TransactionEventMap. It applies different validation rules depending on the action type
  (create vs update).

  ## Parameters
    - `event_map`: The TransactionEventMap struct to create a changeset for
    - `attrs`: Map of attributes to apply to the struct

  ## Returns
    - An Ecto.Changeset with validations applied

  ## Implementation Details
    - For create actions: Validates basic fields and transaction_data
    - For update actions: Additionally validates update_idempk is present

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> attrs = %{action: "create_transaction", instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   source: "accounting_system", source_idempk: "invoice_123",
      ...>   transaction_data: %{status: "pending", entries: [
      ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: "USD"},
      ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: "USD"}
      ...>   ]}}
      iex> changeset = TransactionEventMap.changeset(%TransactionEventMap{}, attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> attrs = %{action: "update", instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   source: "accounting_system", source_idempk: "invoice_123"}
      iex> changeset = TransactionEventMap.changeset(%TransactionEventMap{}, attrs)
      iex> changeset.valid?
      false
  """
  @spec changeset(t() | map(), map()) :: Ecto.Changeset.t()
  def changeset(event_map, %{"action" => action} = attrs) when action in @update_actions do
    update_changeset(event_map, attrs)
  end

  def changeset(event_map, %{action: action} = attrs) when action in @update_actions do
    update_changeset(event_map, attrs)
  end

  def changeset(event_map, attrs) do
    base_changeset(event_map, attrs)
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  @doc """
  Builds a map of trace metadata for logging from an TransactionEventMap.

  This function extracts key fields from the given `TransactionEventMap` struct to provide
  consistent, structured metadata for logging and tracing purposes. The returned map
  includes the action, source, and a composite trace ID.

  ## Parameters

    - `event_map`: The `TransactionEventMap` struct to extract trace information from.

  ## Returns

    - A map containing trace metadata for the event map.
  """
  @spec log_trace(TransactionEventMap.t()) :: map()
  def log_trace(event_map) do
    %{
      is_event_map: true,
      event_action: event_map.action,
      event_source: event_map.source,
      event_trace_id:
        [event_map.source, event_map.source_idempk, event_map.update_idempk]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @doc """
  Builds a map of trace metadata for logging from an TransactionEventMap and an error.

  This function extends `log_trace/1` by also including error information
  when an error value is provided.

  ## Parameters

    - `event_map`: The `TransactionEventMap` struct to extract trace information from.
    - `error`: Any error value to include in the trace metadata.

  ## Returns

    - A map containing trace metadata for the event map and the error.
  """
  @spec log_trace(TransactionEventMap.t(), any()) :: map()
  def log_trace(event_map, error) do
    Map.put(
      log_trace(event_map),
      :error,
      inspect(error, label: "Error")
    )
  end

  @doc """
  Converts an event struct (of type t) into its map representation.
  It also converts the nested transaction data into its map representation.

  This function is useful for transforming the event structure into a plain map,
  which can be easily serialized, inspected, or manipulated further.

  ## Example

    iex> alias DoubleEntryLedger.Event.TransactionData
    iex> alias DoubleEntryLedger.Event.TransactionEventMap
    iex> event = %TransactionEventMap{transaction_data: %TransactionData{}}
    iex> is_map(TransactionEventMap.to_map(event))
    true
  """
  @spec to_map(t) :: map()
  def to_map(event_map) do
    %{
      action: event_map.action,
      instance_id: event_map.instance_id,
      source: event_map.source,
      source_data: event_map.source_data,
      source_idempk: event_map.source_idempk,
      update_idempk: event_map.update_idempk,
      transaction_data: TransactionData.to_map(event_map.transaction_data)
    }
  end

  defp update_changeset(event_map, attrs) do
    base_changeset(event_map, attrs)
    |> validate_required([:update_idempk])
    |> cast_embed(:transaction_data,
      with: &TransactionData.update_event_changeset/2,
      required: true
    )
  end

  defp base_changeset(event_map, attrs) do
    event_map
    |> cast(attrs, [:action, :instance_id, :source, :source_data, :source_idempk, :update_idempk])
    |> validate_required([:action, :instance_id, :source, :source_idempk])
    |> validate_inclusion(:action, Event.actions())
  end
end
