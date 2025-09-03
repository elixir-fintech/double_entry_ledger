defmodule DoubleEntryLedger.Event.TransactionEventMap do
  @moduledoc """
  Defines the TransactionEventMap schema for representing event data in the Double Entry Ledger system.

  This module provides an embedded schema and related functions for creating and validating
  event maps, which serve as the primary data structure for transaction creation and updates.
  TransactionEventMap represents the pre-persistence state of an TransactionEvent, containing all necessary data
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
  * `payload`: Embedded TransactionData containing entries and transaction details

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
  Instead, the TransactionEvent schema handles this at the database level.
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
        payload: %{
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
        payload: %{
          status: "posted",
        }
      })
  """
  import Ecto.Changeset
  use DoubleEntryLedger.Event.EventMap,
    payload: DoubleEntryLedger.Event.TransactionData

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.TransactionData

  alias __MODULE__, as: TransactionEventMap

  @typedoc """
  Represents an TransactionEventMap structure for transaction creation or updates.

  This extends the parameterized EventMap type with TransactionData as the payload type.

  ## Fields

  Inherits all fields from `EventMap.t/1`:
  * `action`: The operation type (:create_transaction or :update_transaction)
  * `instance_id`: UUID of the ledger instance this event belongs to
  * `source`: Identifier of the external system generating the event
  * `source_data`: Optional metadata from the source system
  * `source_idempk`: Primary identifier used for idempotency
  * `update_idempk`: Unique identifier for update operations to maintain idempotency

  Plus the transaction-specific field:
  * `payload`: The embedded transaction data structure
  """
  @type t :: DoubleEntryLedger.Event.EventMap.t(TransactionData.t())

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
    ...>   payload: %{status: "pending", entries: [
    ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: "USD"},
    ...>     %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: "USD"}
    ...>   ]}})
    iex> is_struct(em, TransactionEventMap)

  """
  @spec create(map()) :: {:ok, t()} | {:error, Changeset.t()}
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
    - For create actions: Validates basic fields and payload
    - For update actions: Additionally validates update_idempk is present

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionEventMap
      iex> attrs = %{action: "create_transaction", instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   source: "accounting_system", source_idempk: "invoice_123",
      ...>   payload: %{status: "pending", entries: [
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
  @spec changeset(t() | map(), map()) :: Changeset.t()
  def changeset(event_map, attrs) do
    action = Map.get(attrs, "action") || Map.get(attrs, :action)

    case normalize(action) do
      :update_transaction ->
        update_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &TransactionData.update_event_changeset/2, required: true)
      _ ->
        base_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &TransactionData.changeset/2, required: true)
    end
  end

  @impl true
  def payload_to_map(payload), do: TransactionData.to_map(payload)

  defp normalize(action) when is_binary(action), do: String.to_existing_atom(action)
  defp normalize(action), do: action
end
