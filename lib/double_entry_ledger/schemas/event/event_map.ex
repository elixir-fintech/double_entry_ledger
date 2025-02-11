defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
  Provides functions to process event maps by creating event records and handling associated transactions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Event.TransactionData

  alias __MODULE__, as: EventMap

  @update_actions [:update, "update"]

  @type t :: %EventMap{
    action: Event.action(),
    instance_id: String.t(),
    source: String.t(),
    source_data: map(),
    source_idempk: String.t(),
    update_idempk: String.t() | nil,
    transaction_data: TransactionData.t()
  }

  @primary_key false
  embedded_schema do
    field :action, Ecto.Enum, values: Event.actions
    field :instance_id, :string
    field :source, :string
    field :source_data, :map, default: %{}
    field :source_idempk, :string
    field :update_idempk, :string
    embeds_one :transaction_data, TransactionData
  end

  @doc """
  Builds a validated EventMap or returns a changeset with errors.

  ## Parameters
    - `attrs`: A map containing the event data.

  ## Returns
    - `{:ok, event_map}` on success.
    - `{:error, changeset}` on failure.

  ## Example

    iex> alias DoubleEntryLedger.Event.EventMap
    iex> {:ok, em} = EventMap.create(%{action: "create", instance_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db9", source: "source", source_idempk: "source_idempk",
    ...>   transaction_data: %{status: "pending", entries: [
    ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: "USD"},
    ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: "USD"}
    ...>   ]}})
    iex> is_struct(em, EventMap)

  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %EventMap{}
    |> changeset(attrs)
    |> Changeset.apply_action(:insert)
  end

  def changeset(event_map, %{"action" => action} = attrs) when action in @update_actions do
    update_changeset(event_map, attrs)
  end

  def changeset(event_map, %{action: action} = attrs) when action in @update_actions do
    update_changeset(event_map, attrs)
  end

  def changeset(event_map, attrs) do
    base_changeset(event_map, attrs)
  end

  defp update_changeset(event_map,attrs) do
    base_changeset(event_map, attrs)
    |> validate_required([:update_idempk])
  end

  defp base_changeset(event_map, attrs) do
    event_map
    |> cast(attrs, [:action, :instance_id, :source, :source_data, :source_idempk, :update_idempk])
    |> validate_required([:action, :instance_id, :source, :source_idempk])
    |> validate_inclusion(:action, Event.actions)
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  @doc """
  Converts an event struct (of type t) into its map representation.
  It also converts the nested transaction data into its map representation.

  This function is useful for transforming the event structure into a plain map,
  which can be easily serialized, inspected, or manipulated further.

  ## Example

    iex> alias DoubleEntryLedger.Event.TransactionData
    iex> alias DoubleEntryLedger.Event.EventMap
    iex> event = %EventMap{transaction_data: %TransactionData{}}
    iex> is_map(EventMap.to_map(event))
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
end
