defmodule DoubleEntryLedger.Event.TransactionEventMap do
  @moduledoc """
  Defines the TransactionEventMap schema for representing transaction event data in the Double Entry Ledger system.

  This module provides an embedded schema and related functions for creating and validating
  transaction event maps, which serve as the primary data structure for transaction creation and updates.
  TransactionEventMap represents the pre-persistence state of a TransactionEvent, containing all necessary data
  to either create a new transaction or update an existing one.

  ## Purpose

  TransactionEventMap acts as a validation and structuring layer for transaction-related events
  before they are processed into persistent database records. It ensures data integrity and
  provides a consistent interface for transaction operations across the system.

  ## Architecture

  This module extends the base `DoubleEntryLedger.Event.EventMap` behavior by:

  * Using the EventMap macro to inject common fields and functionality
  * Implementing the `payload_to_map/1` callback for TransactionData serialization
  * Providing action-specific validation through custom changeset logic
  * Supporting both create and update transaction operations

  ## Structure

  TransactionEventMap extends the base EventMap functionality with transaction-specific payload handling.
  It contains the following fields:

  * `action`: The type of action to perform (`:create_transaction` or `:update_transaction`)
  * `instance_address`:  unique address of the instance this event belongs to
  * `source`: Identifier of the external system generating the event
  * `source_data`: Optional map containing additional metadata from the source system
  * `source_idempk`: Primary identifier from the source system (used for idempotency)
  * `update_idempk`: Unique identifier for update operations, enabling multiple distinct updates
     to the same original transaction while maintaining idempotency
  * `payload`: Embedded TransactionData containing entries and transaction details

  ## Key Functions

  * `create/1`: Creates and validates a TransactionEventMap from a map of attributes
  * `changeset/2`: Builds a changeset for validating TransactionEventMap data with action-specific logic
  * `payload_to_map/1`: Converts TransactionData payload to a plain map (EventMap callback)
  * `to_map/1`: Converts a TransactionEventMap struct to a plain map representation (inherited)
  * `log_trace/1,2`: Builds a map of trace metadata for logging from a TransactionEventMap (inherited)

  ## Implementation Details

  ### Action-Specific Validation

  The changeset function applies different validation strategies based on the action type:

  * **Create operations** (`:create_transaction`): Uses standard TransactionData validation
    requiring complete transaction information including balanced entries
  * **Update operations** (`:update_transaction`): Uses specialized update validation that allows
    partial data and requires `update_idempk` for idempotency

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
  Instead, the TransactionEvent schema handles this at the database level.
  Only transactions with status `:pending` can be updated.

  ## Workflow Integration

  TransactionEventMaps are typically created from external input data, validated, and then processed
  by the EventWorker system to create or update transactions in the ledger.

  ## Examples

  Creating a TransactionEventMap for a new transaction:

      {:ok, event_map} = TransactionEventMap.create(%{
        action: "create_transaction",
        instance_address: "some:address",
        source: "accounting_system",
        source_idempk: "invoice_123",
        payload: %{
          status: "pending",
          entries: [
            %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: "USD"},
            %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: "USD"}
          ]
        }
      })

  Creating a TransactionEventMap for updating an existing transaction:

      {:ok, update_map} = TransactionEventMap.create(%{
        action: "update_transaction",
        instance_address: "some:address",
        source: "accounting_system",
        source_idempk: "invoice_123",
        update_idempk: "invoice_123_update_1",
        payload: %{
          status: "posted"
        }
      })
  """
  use Ecto.Schema

  import DoubleEntryLedger.Event.Helper,
    only: [
      fetch_action: 1
    ]

  import Ecto.Changeset,
    only: [
      cast_embed: 3,
      apply_action: 2,
      add_error: 4,
      cast: 3,
      validate_required: 2,
      validate_inclusion: 3,
      validate_format: 3
    ]

  alias DoubleEntryLedger.Event.TransactionData
  alias Ecto.Changeset

  alias __MODULE__, as: TransactionEventMap

  @typedoc """
  Represents a TransactionEventMap structure for transaction creation or updates.

  This type extends the parameterized EventMap type with TransactionData as the payload type,
  providing type safety and clear documentation for transaction-specific event operations.

  ## Type Specification

  This is equivalent to `DoubleEntryLedger.Event.EventMap.t(TransactionData.t())` and includes:

  ## Inherited Fields (from EventMap)

  * `action`: The operation type (`:create_transaction` or `:update_transaction`)
  * `instance_address`: UUID of the ledger instance this event belongs to
  * `source`: Identifier of the external system generating the event
  * `source_data`: Optional metadata from the source system (default: `%{}`)
  * `source_idempk`: Primary identifier used for idempotency
  * `update_idempk`: Unique identifier for update operations to maintain idempotency

  ## Transaction-Specific Field

  * `payload`: The embedded `TransactionData.t()` structure containing transaction details

  ## Usage in Function Signatures

      @spec process_transaction_event(TransactionEventMap.t()) ::
        {:ok, Transaction.t()} | {:error, Changeset.t()}

  ## Examples

      # Type annotation in function
      @spec validate_event(TransactionEventMap.t()) :: boolean()
      def validate_event(%TransactionEventMap{} = event_map) do
        # Implementation
      end
  """
  @type t() :: %TransactionEventMap{
          action: :create_transaction | :update_transaction,
          instance_address: String.t(),
          source: String.t(),
          source_idempk: String.t(),
          update_idempk: String.t() | nil,
          update_source: String.t() | nil,
          payload: TransactionData.t()
        }

  @actions [:create_transaction, :update_transaction]

  @derive {Jason.Encoder,
           only: [
             :action,
             :instance_address,
             :source,
             :source_idempk,
             :update_idempk,
             :update_source,
             :payload
           ]}

  @primary_key false
  embedded_schema do
    field(:action, Ecto.Enum, values: @actions)
    field(:instance_address, :string)
    field(:source, :string)
    field(:source_idempk, :string)
    field(:update_idempk, :string)
    field(:update_source, :string)
    embeds_one(:payload, TransactionData, on_replace: :delete)
  end

  def actions(), do: @actions

  @doc """
  Builds a validated TransactionEventMap or returns a changeset with errors.

  This function creates a complete TransactionEventMap from raw input data by applying
  all necessary validations. It serves as the primary entry point for creating
  validated transaction events from external input.

  ## Parameters

  * `attrs`: A map containing the event data with both common EventMap fields and transaction payload

  ## Returns

  * `{:ok, event_map}` - Successfully validated TransactionEventMap struct
  * `{:error, changeset}` - Ecto.Changeset containing validation errors

  ## Validation Process

  The function applies comprehensive validation including:

  1. Common EventMap field validation (action, instance_address, source, etc.)
  2. Action-specific requirements (update_idempk for updates)
  3. TransactionData payload validation appropriate to the action type
  4. Cross-field validation and business rule enforcement

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> attrs = %{
      ...>   action: "create_transaction",
      ...>   instance_address: "some:address",
      ...>   source: "accounting_system",
      ...>   source_idempk: "invoice_123",
      ...>   payload: %{
      ...>     status: "pending",
      ...>     entries: [
      ...>       %{account_address: "asset:account", amount: 100, currency: "USD"},
      ...>       %{account_address: "cash:account", amount: -100, currency: "USD"}
      ...>     ]
      ...>   }
      ...> }
      iex> {:ok, event_map} = TransactionEventMap.create(attrs)
      iex> event_map.action
      :create_transaction
      iex> event_map.source
      "accounting_system"

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> invalid_attrs = %{action: "create_transaction", source: "test"}
      iex> {:error, changeset} = TransactionEventMap.create(invalid_attrs)
      iex> changeset.valid?
      false
  """
  @spec create(map()) :: {:ok, t()} | {:error, Changeset.t(TransactionEventMap.t())}
  def create(attrs) do
    %TransactionEventMap{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Creates a changeset for validating TransactionEventMap attributes with action-specific logic.

  This function builds an Ecto changeset that validates the required fields and structure
  of a TransactionEventMap. It applies different validation rules depending on the action type,
  ensuring that create and update operations have appropriate requirements.

  ## Parameters

  * `event_map`: The TransactionEventMap struct to create a changeset for
  * `attrs`: Map of attributes to apply to the struct

  ## Returns

  * An `Ecto.Changeset` with all validations applied

  ## Validation Strategy

  The function uses action-aware validation:

  ### Create Transaction Validation
  * Applies base EventMap validation (action, instance_address, source, source_idempk required)
  * Validates payload using `TransactionData.changeset/2` (requires complete transaction data)
  * Does not require `update_idempk`

  ### Update Transaction Validation
  * Applies update EventMap validation (includes all base validation plus requires `update_idempk`)
  * Validates payload using `TransactionData.update_event_changeset/2` (allows partial data)
  * Enforces update-specific business rules

  ## Implementation Details

  The function normalizes string action values to atoms and routes to the appropriate
  validation strategy. This allows flexible input handling while maintaining type safety.

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> attrs = %{
      ...>   action: "create_transaction",
      ...>   instance_address: "some:address",
      ...>   source: "accounting_system",
      ...>   source_idempk: "invoice_123",
      ...>   payload: %{
      ...>     status: "pending",
      ...>     entries: [
      ...>       %{account_address: "cash:account", amount: 100, currency: "USD"},
      ...>       %{account_address: "asset:account", amount: -100, currency: "USD"}
      ...>     ]
      ...>   }
      ...> }
      iex> changeset = TransactionEventMap.changeset(%TransactionEventMap{}, attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> update_attrs = %{
      ...>   action: "update_transaction",
      ...>   instance_address: "some:address",
      ...>   source: "accounting_system",
      ...>   source_idempk: "invoice_123",
      ...>   update_idempk: "update_1",
      ...>   payload: %{status: "posted"}
      ...> }
      iex> changeset = TransactionEventMap.changeset(%TransactionEventMap{}, update_attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> invalid_attrs = %{action: "update_transaction", source: "test"}
      iex> changeset = TransactionEventMap.changeset(%TransactionEventMap{}, invalid_attrs)
      iex> changeset.valid?
      false
  """
  @spec changeset(t() | map(), map()) :: Changeset.t(TransactionEventMap.t())
  def changeset(event_map, attrs) do
    case fetch_action(attrs) do
      :update_transaction ->
        update_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &TransactionData.update_event_changeset/2, required: true)

      :create_transaction ->
        base_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &TransactionData.changeset/2, required: true)

      val ->
        base_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &TransactionData.changeset/2, required: true)
        |> add_error(:action, "invalid in this context", value: "#{val}")
    end
  end

  def base_changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :action,
      :instance_address,
      :source,
      :source_idempk
    ])
    |> validate_required([:action, :instance_address, :source, :source_idempk])
    |> validate_format(:source, ~r/^[a-z0-9](?:[a-z0-9_-]){1,29}/)
    |> validate_format(:source_idempk, ~r/^[A-Za-z0-9](?:[A-Za-z0-9._:-]){0,127}$/)
    |> validate_inclusion(:action, @actions)
  end

  def update_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:update_idempk, :update_source])
    |> base_changeset(attrs)
    |> validate_required([:update_idempk])
  end

  @spec to_map(struct()) :: map()
  def to_map(event_map) do
    %{
      action: Map.get(event_map, :action),
      instance_address: Map.get(event_map, :instance_address),
      source: Map.get(event_map, :source),
      source_idempk: Map.get(event_map, :source_idempk),
      update_idempk: Map.get(event_map, :update_idempk),
      update_source: Map.get(event_map, :update_source),
      payload: TransactionData.to_map(Map.get(event_map, :payload))
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end
end
