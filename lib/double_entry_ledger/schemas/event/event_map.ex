defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
  Shared behaviour and defaults for EventMap-like modules.

  Provides:
  - Common field injection via macro
  - Base changeset functionality
  - Default implementations of log_trace/1,2 and to_map/1
  - Behaviour callbacks for payload handling

  Use this module with `use` in your event map schema to inject default implementations.
  """
  import Ecto.Changeset, only: [cast: 3, validate_required: 2, validate_inclusion: 3]

  @typedoc """
  Generic EventMap type parameterized by payload type.

  This allows EventMap implementations to specify their payload type
  while inheriting the common field structure.
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

  @callback payload_to_map(any()) :: map()

  defmacro __using__(opts) do
    payload_mod = Keyword.get(opts, :payload, nil)

    quote do
      @behaviour DoubleEntryLedger.Event.EventMap

      use Ecto.Schema
      import DoubleEntryLedger.Event.EventMap, only: [
        base_changeset: 2, update_changeset: 2]

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
        field :action, Ecto.Enum, values: DoubleEntryLedger.Event.actions()
        field :instance_id, :string
        field :source, :string
        field :source_data, :map, default: %{}
        field :source_idempk, :string
        field :update_idempk, :string
        embeds_one(:payload, unquote(payload_mod), on_replace: :delete)
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
  Base changeset for common fields validation.
  """
  def base_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:action, :instance_id, :source, :source_data, :source_idempk, :update_idempk])
    |> validate_required([:action, :instance_id, :source, :source_idempk])
    |> validate_inclusion(:action, DoubleEntryLedger.Event.actions())
  end

  def update_changeset(struct, attrs) do
    struct
    |> base_changeset(attrs)
    |> validate_required([:update_idempk])
  end

  @doc """
  Default log_trace implementation.
  """
  @spec log_trace(struct()) :: map()
  def log_trace(event_map) do
    %{
      is_event_map: true,
      event_action: Map.get(event_map, :action),
      event_source: Map.get(event_map, :source),
      event_trace_id:
        [Map.get(event_map, :source), Map.get(event_map, :source_idempk), Map.get(event_map, :update_idempk)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @doc """
  Default log_trace implementation with error.
  """
  @spec log_trace(struct(), any()) :: map()
  def log_trace(event_map, error) do
    Map.put(log_trace(event_map), :error, inspect(error, label: "Error"))
  end

  @doc """
  Default to_map implementation that auto-detects payload module.
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
end
