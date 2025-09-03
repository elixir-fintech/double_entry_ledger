defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
  A behavior module that provides shared functionality for EventMap-like schemas in the Double Entry Ledger system.

  This module serves as a foundation for creating event map schemas that represent pre-persistence
  event data. It provides common field definitions, validation logic, and utility functions
  that are shared across different types of event maps.

  ## Purpose

  EventMap modules are used to validate and structure event data before it gets processed
  into persistent entities. They act as a validation layer that ensures incoming data
  meets the system's requirements before being committed to the database.

  ## Usage

  To create an EventMap module, use this module with the `use` macro and specify the payload type:

      defmodule MyApp.SomeEventMap do
        use DoubleEntryLedger.Event.EventMap,
          payload: MyApp.SomePayloadSchema

        @impl true
        def payload_to_map(payload), do: MyApp.SomePayloadSchema.to_map(payload)
      end

  ## Provided Functionality

  When you `use` this module, it automatically provides:

  * **Schema Definition**: Common fields like `action`, `instance_id`, `source`, etc.
  * **JSON Encoding**: Automatic `Jason.Encoder` derivation for all fields
  * **Base Validation**: Common changeset validations via `base_changeset/2` and `update_changeset/2`
  * **Utility Functions**: Default implementations of `log_trace/1,2` and `to_map/1`
  * **Behavior Contract**: Enforces implementation of `payload_to_map/1`

  ## Common Fields

  All EventMap modules include these fields:

  * `action` - The type of operation to perform (atom from predefined list)
  * `instance_id` - UUID of the ledger instance
  * `source` - Identifier of the external system generating the event
  * `source_data` - Optional metadata from the source system
  * `source_idempk` - Primary identifier for idempotency
  * `update_idempk` - Secondary identifier for update operation idempotency
  * `payload` - The embedded payload schema (type specified in `use` options)

  ## Behavior Callbacks

  Implementing modules must provide:

  * `payload_to_map/1` - Convert the payload to a plain map representation

  ## Default Implementations

  The following functions are provided with sensible defaults but can be overridden:

  * `log_trace/1,2` - Create structured logging metadata
  * `to_map/1` - Convert the entire event map to a plain map

  ## Validation Strategy

  The module provides two changeset functions:

  * `base_changeset/2` - Validates common required fields for create operations
  * `update_changeset/2` - Extends base validation to require `update_idempk` for updates

  ## Examples

      # Define a custom EventMap
      defmodule MyApp.OrderEventMap do
        use DoubleEntryLedger.Event.EventMap,
          payload: MyApp.OrderData

        @impl true
        def payload_to_map(payload), do: MyApp.OrderData.to_map(payload)
      end

      # Use the EventMap
      {:ok, event_map} = MyApp.OrderEventMap.create(%{
        action: "create_order",
        instance_id: "550e8400-e29b-41d4-a716-446655440000",
        source: "web_app",
        source_idempk: "order_123",
        payload: %{...}
      })
  """
  require Ecto.Schema
  import Ecto.Changeset, only: [cast: 3, validate_required: 2, validate_inclusion: 3]

  @typedoc """
  Generic EventMap type parameterized by payload type.

  This type definition allows EventMap implementations to specify their payload type
  while inheriting the common field structure. The payload type parameter enables
  type safety and better documentation for specific EventMap implementations.

  ## Type Parameters

  * `payload_type` - The type of the embedded payload schema (e.g., `TransactionData.t()`)

  ## Fields

  * `__struct__` - The module name of the implementing EventMap
  * `action` - The operation type as defined in `DoubleEntryLedger.Event.actions()`
  * `instance_id` - UUID string identifying the ledger instance
  * `source` - String identifier of the external system
  * `source_data` - Optional map containing additional metadata
  * `source_idempk` - String identifier for idempotency (primary key from source)
  * `update_idempk` - Optional string identifier for update operation idempotency
  * `payload` - The embedded payload data of the specified type

  ## Examples

      # Specific implementation type
      @type transaction_event_map :: EventMap.t(TransactionData.t())

      # Generic usage in function signatures
      @spec process_event(EventMap.t(any())) :: {:ok, term()} | {:error, term()}
  """
  @type t(payload_type) :: %{
          __struct__: module(),
          action: DoubleEntryLedger.Event.action(),
          instance_id: Ecto.UUID.t(),
          source: String.t(),
          source_data: map() | nil,
          source_idempk: String.t(),
          update_idempk: String.t() | nil,
          payload: payload_type
        }

  @doc """
  Callback to convert a payload struct to a plain map representation.

  This callback must be implemented by modules using EventMap. It defines how
  the payload should be serialized when converting the entire EventMap to a map.

  ## Parameters

  * `payload` - The payload struct to convert

  ## Returns

  * A map representation of the payload

  ## Example Implementation

      @impl true
      def payload_to_map(%TransactionData{} = payload) do
        %{
          status: payload.status,
          entries: Enum.map(payload.entries, &EntryData.to_map/1)
        }
      end
  """
  @callback payload_to_map(any()) :: map()

  @doc """
  Macro that injects EventMap functionality into the using module.

  This macro sets up the complete EventMap infrastructure including schema definition,
  validation functions, and utility methods. It's the primary way to create EventMap modules.

  ## Options

  * `:payload` - The module name of the payload schema to embed (required)

  ## Generated Code

  The macro generates:

  * An embedded Ecto schema with all common EventMap fields
  * JSON encoder configuration for API serialization
  * Default implementations of utility functions that can be overridden
  * Imports for validation helper functions

  ## Example

      defmodule MyApp.TransactionEventMap do
        use DoubleEntryLedger.Event.EventMap,
          payload: MyApp.TransactionData

        # Must implement the behavior callback
        @impl true
        def payload_to_map(payload), do: MyApp.TransactionData.to_map(payload)

        # Can override default implementations
        def log_trace(event_map) do
          super(event_map)
          |> Map.put(:custom_field, "custom_value")
        end
      end
  """
  defmacro __using__(opts) do
    payload_mod = Keyword.get(opts, :payload, nil)

    quote do
      @behaviour DoubleEntryLedger.Event.EventMap

      use Ecto.Schema

      import DoubleEntryLedger.Event.EventMap,
        only: [
          base_changeset: 2,
          update_changeset: 2,
          fetch_action: 1
        ]

      @derive {Jason.Encoder,
               only: [
                 :action,
                 :instance_id,
                 :source,
                 :source_data,
                 :source_idempk,
                 :update_idempk,
                 :payload
               ]}

      @primary_key false
      embedded_schema do
        field(:action, Ecto.Enum, values: DoubleEntryLedger.Event.actions())
        field(:instance_id, :string)
        field(:source, :string)
        field(:source_data, :map, default: %{})
        field(:source_idempk, :string)
        field(:update_idempk, :string)

        if unquote(payload_mod) == :map do
          field(:payload, :map)
        else
          embeds_one(:payload, unquote(payload_mod), on_replace: :delete)
        end
      end

      @doc false
      def log_trace(event_map),
        do: DoubleEntryLedger.Event.EventMap.log_trace(event_map)

      @doc false
      def log_trace(event_map, error),
        do: DoubleEntryLedger.Event.EventMap.log_trace(event_map, error)

      @doc false
      def to_map(event_map),
        do: DoubleEntryLedger.Event.EventMap.to_map(event_map)

      defoverridable log_trace: 1, log_trace: 2, to_map: 1
    end
  end

  @doc """
  Creates a base changeset for validating common EventMap fields.

  This function provides validation for the core fields that are required for all
  EventMap operations. It handles type casting and validates required fields and
  acceptable action values.

  ## Parameters

  * `struct` - The EventMap struct to build the changeset for
  * `attrs` - Map of attributes to validate and apply

  ## Returns

  * An `Ecto.Changeset` with validations applied

  ## Validations Applied

  * Casts all common fields from the attributes
  * Requires: `action`, `instance_id`, `source`, `source_idempk`
  * Validates `action` is in the allowed list from `DoubleEntryLedger.Event.actions()`

  ## Examples

      iex> defmodule Elixir.TestEventMap do
      ...>   use DoubleEntryLedger.Event.EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> attrs = %{action: :create_transaction, instance_id: "550e8400-e29b-41d4-a716-446655440000", source: "test", source_idempk: "123"}
      iex> changeset = DoubleEntryLedger.Event.EventMap.base_changeset(struct!(TestEventMap, %{}), attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule Elixir.TestEventMap2 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> attrs = %{action: :invalid_action, source: "test"}
      iex> changeset = EventMap.base_changeset(struct!(TestEventMap2, %{}), attrs)
      iex> changeset.valid?
      false
  """
  def base_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:action, :instance_id, :source, :source_data, :source_idempk, :update_idempk])
    |> validate_required([:action, :instance_id, :source, :source_idempk])
    |> validate_inclusion(:action, DoubleEntryLedger.Event.actions())
  end

  @doc """
  Creates a changeset for update operations with additional validation.

  This function extends `base_changeset/2` by adding validation for the `update_idempk`
  field, which is required for update operations to maintain idempotency.

  ## Parameters

  * `struct` - The EventMap struct to build the changeset for
  * `attrs` - Map of attributes to validate and apply

  ## Returns

  * An `Ecto.Changeset` with base validations plus update-specific requirements

  ## Additional Validations

  All validations from `base_changeset/2` plus:
  * Requires `update_idempk` to be present

  ## Examples

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule Elixir.TestEventMap3 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> attrs = %{action: :update_transaction, instance_id: "550e8400-e29b-41d4-a716-446655440000", source: "test", source_idempk: "123", update_idempk: "update_456"}
      iex> changeset = EventMap.update_changeset(struct!(TestEventMap3, %{}), attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule Elixir.TestEventMap4 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> attrs = %{action: :update_transaction, instance_id: "550e8400-e29b-41d4-a716-446655440000", source: "test", source_idempk: "123"}
      iex> changeset = EventMap.update_changeset(struct!(TestEventMap4, %{}), attrs)
      iex> changeset.valid?
      false
  """
  def update_changeset(struct, attrs) do
    struct
    |> base_changeset(attrs)
    |> validate_required([:update_idempk])
  end

  @doc """
  Creates structured metadata for logging from an EventMap.

  This function extracts key identifying information from an EventMap to create
  a consistent logging context. This is useful for tracing events through the
  system and debugging issues.

  ## Parameters

  * `event_map` - The EventMap struct to extract trace information from

  ## Returns

  * A map containing trace metadata with consistent key structure

  ## Generated Fields

  * `:is_event_map` - Always `true` to identify log entries from EventMaps
  * `:event_action` - The action field from the EventMap
  * `:event_source` - The source field from the EventMap
  * `:event_trace_id` - Composite identifier joining source, source_idempk, and update_idempk

  ## Examples

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule Elixir.TestEventMap5 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> event_map = struct!(TestEventMap5, %{action: :create_transaction, source: "web_app", source_idempk: "order_123", update_idempk: nil})
      iex> trace = EventMap.log_trace(event_map)
      iex> trace.is_event_map
      true
      iex> trace.event_trace_id
      "web_app-order_123"

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule TestEventMap6 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> event_map = struct!(TestEventMap6, %{action: :update_transaction, source: "api", source_idempk: "inv_456", update_idempk: "update_1"})
      iex> trace = EventMap.log_trace(event_map)
      iex> trace.event_trace_id
      "api-inv_456-update_1"
  """
  @spec log_trace(struct()) :: map()
  def log_trace(event_map) do
    %{
      is_event_map: true,
      event_action: Map.get(event_map, :action),
      event_source: Map.get(event_map, :source),
      event_trace_id:
        [
          Map.get(event_map, :source),
          Map.get(event_map, :source_idempk),
          Map.get(event_map, :update_idempk)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @doc """
  Creates structured metadata for logging with error information.

  This function extends `log_trace/1` by adding error details to the trace metadata.
  This is particularly useful for logging failed operations while maintaining
  the same trace context.

  ## Parameters

  * `event_map` - The EventMap struct to extract trace information from
  * `error` - The error information to include in the trace

  ## Returns

  * A map containing all trace metadata from `log_trace/1` plus error details

  ## Additional Fields

  * `:error` - Inspected representation of the error with "Error" label

  ## Examples

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule TestEventMap7 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> event_map = struct!(TestEventMap7, %{action: :create_transaction, source: "web_app", source_idempk: "order_123"})
      iex> error = {:error, "Something went wrong"}
      iex> trace = EventMap.log_trace(event_map, error)
      iex> trace.is_event_map
      true
      iex> String.contains?(trace.error, "Something went wrong")
      true
  """
  @spec log_trace(struct(), any()) :: map()
  def log_trace(event_map, error) do
    Map.put(log_trace(event_map), :error, inspect(error, label: "Error"))
  end

  @doc """
  Converts an EventMap struct to a plain map representation.

  This function creates a serializable map from an EventMap by extracting all
  fields and converting the payload using the module's `payload_to_map/1` callback.
  This is useful for API responses, persistence, or debugging.

  ## Parameters

  * `event_map` - The EventMap struct to convert

  ## Returns

  * A map containing all EventMap fields with the payload converted to a map

  ## Implementation Details

  The function automatically detects the EventMap module from the struct's `__struct__`
  field and calls the appropriate `payload_to_map/1` implementation for payload conversion.

  ## Examples

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> defmodule TestEventMap8 do
      ...>   use EventMap, payload: :map
      ...>   def payload_to_map(payload), do: payload
      ...> end
      iex> event_map = struct!(TestEventMap8, %{action: :create_transaction, instance_id: "550e8400-e29b-41d4-a716-446655440000", source: "test", source_idempk: "123", payload: %{amount: 100}})
      iex> map = EventMap.to_map(event_map)
      iex> map.action
      :create_transaction
      iex> map.payload
      %{amount: 100}
  """
  @spec to_map(struct()) :: map()
  def to_map(%{__struct__: mod} = event_map) do
    payload_map = mod.payload_to_map(Map.get(event_map, :payload))

    %{
      action: Map.get(event_map, :action),
      instance_id: Map.get(event_map, :instance_id),
      source: Map.get(event_map, :source),
      source_data: Map.get(event_map, :source_data),
      source_idempk: Map.get(event_map, :source_idempk),
      update_idempk: Map.get(event_map, :update_idempk),
      payload: payload_map
    }
  end

  @doc """
  Fetches and normalizes the action value from a map.

  Accepts both atom and string keys. When the action is a string, it is converted
  using String.to_existing_atom/1. Returns nil when no action is present.

  ## Examples

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> # Ensure atoms exist for to_existing_atom/1
      iex> :create_transaction
      iex> :update_transaction
      iex> EventMap.fetch_action(%{"action" => "create_transaction"})
      :create_transaction
      iex> EventMap.fetch_action(%{action: :update_transaction})
      :update_transaction
      iex> EventMap.fetch_action(%{})
      nil
  """
  @spec fetch_action(map()) :: atom() | nil
  def fetch_action(attrs), do: normalize(Map.get(attrs, "action") || Map.get(attrs, :action))

  @spec normalize(atom() | String.t()) :: atom()
  defp normalize(action) when is_binary(action), do: String.to_existing_atom(action)
  defp normalize(action), do: action
end
