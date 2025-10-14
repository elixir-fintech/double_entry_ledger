defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
  A behavior module that provides shared functionality for EventMap schemas in the Double Entry Ledger system.

  This module serves as a foundation for creating event map schemas that represent pre-persistence
  event data. It provides common field definitions, validation logic, and utility functions
  that are shared across different types of event maps.

  ## Purpose

  EventMap modules are used to validate and structure event data before it gets processed
  into persistent entities. They act as a validation layer that ensures incoming data
  meets the system's requirements before being committed to the database.

  The EventMap pattern provides:
  * **Type Safety**: Structured data with compile-time validation
  * **Idempotency**: Built-in support for duplicate operation detection
  * **Traceability**: Consistent logging and debugging metadata
  * **Extensibility**: Pluggable payload validation for different event types

  ## Usage

  To create an EventMap module, use this module with the `use` macro and specify the payload type:

      defmodule MyApp.TransactionEventMap do
        use DoubleEntryLedger.Event.EventMap,
          payload: MyApp.TransactionData

        # Must implement the behavior callback
        @impl true
        def payload_to_map(payload), do: MyApp.TransactionData.to_map(payload)

        # Optional: Custom changeset logic
        def changeset(event_map, attrs) do
          case fetch_action(attrs) do
            :create_transaction ->
              base_changeset(event_map, attrs)
              |> cast_embed(:payload, with: &MyApp.TransactionData.changeset/2, required: true)

            :update_transaction ->
              update_changeset(event_map, attrs)
              |> cast_embed(:payload, with: &MyApp.TransactionData.update_changeset/2)

            _ ->
              base_changeset(event_map, attrs)
              |> add_error(:action, :invalid_in_context)
          end
        end
      end

  ## Provided Functionality

  When you `use` this module, it automatically provides:

  * **Schema Definition**: Common fields like `action`, `instance_address`, `source`, etc.
  * **JSON Encoding**: Automatic `Jason.Encoder` derivation for all fields
  * **Base Validation**: Common changeset validations via `base_changeset/2` and `update_changeset/2`
  * **Utility Functions**: Default implementations of `log_trace/1,2` and `to_map/1`
  * **Behavior Contract**: Enforces implementation of `payload_to_map/1`

  ## Common Fields

  All EventMap modules include these fields:

  * `action` - The type of operation to perform (atom from predefined list)
  * `instance_address` - Unique address of the ledger instance
  * `source` - Identifier of the external system generating the event
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

  Most implementations will want to define their own `changeset/2` function that calls
  these base functions and adds payload-specific validation.

  ## Examples

      # Define a custom EventMap
      defmodule MyApp.OrderEventMap do
        use DoubleEntryLedger.Event.EventMap,
          payload: MyApp.OrderData

        @impl true
        def payload_to_map(payload), do: MyApp.OrderData.to_map(payload)

        def changeset(event_map, attrs) do
          base_changeset(event_map, attrs)
          |> cast_embed(:payload, with: &MyApp.OrderData.changeset/2, required: true)
        end
      end

      # Use the EventMap
      {:ok, event_map} = MyApp.OrderEventMap.changeset(%MyApp.OrderEventMap{}, %{
        action: "create_order",
        instance_address: "some:ledger",
        source: "web_app",
        source_idempk: "order_123",
        payload: %{...}
      }) |> Ecto.Changeset.apply_action(:insert)
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
  * `instance_address` - Unique address of the ledger instance
  * `source` - String identifier of the external system
  * `source_idempk` - String identifier for idempotency (primary key from source)
  * `update_idempk` - Optional string identifier for update operation idempotency
  * `payload` - The embedded payload data of the specified type

  ## Examples

      # Specific implementation type
      @type transaction_event_map :: EventMap.t(TransactionData.t())

      # Generic usage in function signatures
      @spec process_event(EventMap.t(any())) :: {:ok, term()} | {:error, term()}

      # Pattern matching with types
      def handle_event(%{__struct__: mod} = event_map) when is_struct(event_map, EventMap) do
        # Process the event
      end
  """
  @type t(payload_type) :: %{
          __struct__: module(),
          action: DoubleEntryLedger.Event.action(),
          instance_address: String.t(),
          source: String.t(),
          source_idempk: String.t(),
          update_idempk: String.t() | nil,
          update_source: String.t() | nil,
          payload: payload_type
        }

  @doc """
  Callback to convert a payload struct to a plain map representation.

  This callback must be implemented by modules using EventMap. It defines how
  the payload should be serialized when converting the entire EventMap to a map.

  The implementation should handle conversion of nested structs and ensure
  the resulting map is serializable (e.g., for JSON encoding).

  ## Parameters

  * `payload` - The payload struct to convert

  ## Returns

  * A map representation of the payload

  ## Example Implementation

      @impl true
      def payload_to_map(%TransactionData{} = payload) do
        %{
          status: payload.status,
          entries: Enum.map(payload.entries, &EntryData.to_map/1),
          metadata: payload.metadata
        }
      end

      # For simple payloads, you might just return the map directly
      @impl true
      def payload_to_map(payload) when is_map(payload), do: payload
  """
  @callback payload_to_map(any()) :: map()

  @callback base_changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  @callback update_changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()

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

      @behaviour DoubleEntryLedger.Event.EventMap

      use Ecto.Schema

      import DoubleEntryLedger.Event.EventMap,
        only: [
          fetch_action: 1
        ]

      @primary_key false
      embedded_schema do
        field(:action, Ecto.Enum,
          values:
            case "#{unquote(payload_mod)}" do
              "AccountData" -> DoubleEntryLedger.Event.actions(:account)
              "TransactionData" -> DoubleEntryLedger.Event.actions(:transaction)
              _ -> DoubleEntryLedger.Event.actions()
            end
        )

        field(:instance_address, :string)
        field(:source, :string)
        field(:source_idempk, :string)
        field(:update_idempk, :string)
        field(:update_source, :string)

        if unquote(payload_mod) == :map do
          field(:payload, :map)
        else
          embeds_one(:payload, unquote(payload_mod), on_replace: :delete)
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
      * Requires: `action`, `instance_address`, `source`, `source_idempk`
      * Validates `action` is in the allowed list from `DoubleEntryLedger.Event.actions(type)`

      """
      def base_changeset(struct, attrs) do
        struct
        |> cast(attrs, [
          :action,
          :instance_address,
          :source,
          :source_idempk
        ])
        |> validate_required([:action, :instance_address, :source, :source_idempk])
        |> validate_inclusion(
          :action,
          case "#{unquote(payload_mod)}" do
            "AccountData" -> DoubleEntryLedger.Event.actions(:account)
            "TransactionData" -> DoubleEntryLedger.Event.actions(:transaction)
            _ -> DoubleEntryLedger.Event.actions()
          end
        )
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

      """
      def update_changeset(struct, attrs) do
        struct
        |> cast(attrs, [:update_idempk, :update_source])
        |> base_changeset(attrs)
        |> validate_required([:update_idempk])
      end

      @doc false
      def to_map(event_map),
        do: DoubleEntryLedger.Event.EventMap.to_map(event_map)

      defoverridable to_map: 1
    end
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
      iex> event_map = struct!(TestEventMap8, %{action: :create_transaction, instance_address: "some:ledger", source: "test", source_idempk: "123", payload: %{amount: 100}})
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
      instance_address: Map.get(event_map, :instance_address),
      source: Map.get(event_map, :source),
      source_idempk: Map.get(event_map, :source_idempk),
      update_idempk: Map.get(event_map, :update_idempk),
      update_source: Map.get(event_map, :update_source),
      payload: payload_map
    }
  end

  @doc """
  Fetches and normalizes the action value from a map.

  Accepts both atom and string keys ("action" and :action). When the action is a string,
  it is converted using `String.to_existing_atom/1`. Returns `nil` when no action is present.

  This function is useful for handling incoming data that may have string or atom keys,
  which is common when dealing with external APIs or JSON data.

  ## Parameters

  * `attrs` - Map containing potential action data

  ## Returns

  * `atom()` - The normalized action as an atom
  * `nil` - When no action is found

  ## Examples

      iex> alias DoubleEntryLedger.Event.EventMap
      iex> # Ensure atoms exist for to_existing_atom/1
      iex> :create_transaction
      :create_transaction
      iex> :update_transaction
      :update_transaction
      iex> EventMap.fetch_action(%{"action" => "create_transaction"})
      :create_transaction
      iex> EventMap.fetch_action(%{action: :update_transaction})
      :update_transaction
      iex> EventMap.fetch_action(%{})
      nil
      iex> EventMap.fetch_action(%{"other_key" => "value"})
      nil
  """
  @spec fetch_action(map()) :: atom() | nil
  def fetch_action(attrs), do: normalize(Map.get(attrs, "action") || Map.get(attrs, :action))

  @spec normalize(atom() | String.t() | nil) :: atom() | nil
  defp normalize(action) when is_binary(action), do: String.to_existing_atom(action)
  defp normalize(action) when is_atom(action), do: action
  defp normalize(nil), do: nil
end
