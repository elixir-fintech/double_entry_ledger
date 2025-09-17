defmodule DoubleEntryLedger.Event.AccountEventMap do
  @moduledoc """
  EventMap implementation for account-related operations in the Double Entry Ledger system.

  This module provides validation and structure for account creation events. It extends
  the base EventMap functionality with account-specific payload validation using the
  `AccountData` schema.

  ## Purpose

  The AccountEventMap is responsible for:
  * Validating account creation event data before persistence
  * Ensuring proper structure and required fields for account operations
  * Providing type safety for account-specific payloads
  * Converting account data to serializable map format

  ## Supported Actions

  Currently supports:
  * `:create_account` - Creates a new account in the ledger instance

  ## Usage

      # Create a valid account event
      {:ok, event_map} = AccountEventMap.create(%{
        action: :create_account,
        instance_id: "550e8400-e29b-41d4-a716-446655440000",
        source: "accounting_system",
        source_idempk: "acc_12345",
        payload: %{
          name: "Cash Account",
          type: :asset,
          currency: "USD"
        }
      })

      # Convert to map for serialization
      map_data = AccountEventMap.to_map(event_map)

  ## Validation

  The module validates:
  * All base EventMap fields (action, instance_id, source, source_idempk)
  * Action must be `:create_account`
  * Payload must conform to `AccountData` schema requirements
  * Required payload fields based on account type

  ## Error Handling

      # Invalid action
      {:error, changeset} = AccountEventMap.create(%{
        action: :invalid_action,
        # ... other fields
      })

      # Missing required fields
      {:error, changeset} = AccountEventMap.create(%{
        action: :create_account,
        # missing required fields
      })

  ## Type Safety

  The module provides compile-time type checking through:

      @type t :: EventMap.t(AccountData.t())

  This ensures that the payload is always of type `AccountData.t()`.
  """
  import Ecto.Changeset, only: [cast_embed: 3, apply_action: 2, add_error: 4]

  alias DoubleEntryLedger.Event.{EventMap, AccountData}
  alias Ecto.Changeset

  use EventMap, payload: AccountData

  alias __MODULE__, as: AccountEventMap

  @typedoc """
  Type definition for AccountEventMap struct.

  Represents an EventMap specifically for account operations with an `AccountData`
  payload. This provides type safety and clear documentation for functions that
  work with account events.

  ## Usage in Function Signatures

      @spec process_account_event(AccountEventMap.t()) :: {:ok, Account.t()} | {:error, term()}
      def process_account_event(%AccountEventMap{} = event_map) do
        # Implementation with type-safe access to AccountData payload
      end

  ## Pattern Matching

      def handle_event(%AccountEventMap{action: :create_account, payload: payload}) do
        # payload is guaranteed to be AccountData.t()
      end
  """
  @type t :: EventMap.t(AccountData.t())

  @doc """
  Creates and validates an AccountEventMap from the given attributes.

  This is the primary entry point for creating account events. It performs
  full validation including payload validation and returns either a valid
  EventMap struct or validation errors.

  ## Parameters

  * `attrs` - Map containing the event attributes including payload data

  ## Returns

  * `{:ok, AccountEventMap.t()}` - Successfully created and validated event map
  * `{:error, Ecto.Changeset.t()}` - Validation errors

  ## Required Attributes

  * `action` - Must be `:create_account` or `"create_account"`
  * `instance_id` - UUID string of the ledger instance
  * `source` - String identifier of the external system
  * `source_idempk` - String identifier for idempotency
  * `payload` - Map containing account data (see `AccountData` for requirements)

  ## Optional Attributes

  * `source_data` - Additional metadata from the source system
  * `update_idempk` - For update operations (not used for account creation)

  ## Examples

      iex> attrs = %{
      ...>   action: :create_account,
      ...>   instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   source: "web_app",
      ...>   source_idempk: "acc_123",
      ...>   payload: %{
      ...>     name: "Test Account",
      ...>     type: :asset,
      ...>     currency: "USD"
      ...>   }
      ...> }
      iex> {:ok, event_map} = DoubleEntryLedger.Event.AccountEventMap.create(attrs)
      iex> event_map.action
      :create_account
      iex> event_map.payload.name
      "Test Account"

  ## Error Examples

      # Invalid action
      iex> attrs = %{action: :invalid_action, source: "test"}
      iex> {:error, changeset} = DoubleEntryLedger.Event.AccountEventMap.create(attrs)
      iex> changeset.valid?
      false
      iex> changeset.errors[:action]
      {"invalid in this context", [{:value, "invalid_action"}]}
  """
  @spec create(map()) :: {:ok, t()} | {:error, Changeset.t()}
  def create(attrs) do
    %AccountEventMap{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Creates a changeset for AccountEventMap validation.

  This function handles action-specific validation logic. It validates the base
  EventMap fields and then applies account-specific payload validation based
  on the action type.

  ## Parameters

  * `event_map` - The AccountEventMap struct to validate (can be empty for new records)
  * `attrs` - Map of attributes to validate and apply

  ## Returns

  * `Ecto.Changeset.t()` - Changeset with validation results

  ## Validation Logic

  The function switches on the action to determine validation:

  * `:create_account` - Validates base fields + requires valid AccountData payload
  * `:update_account` - Validates base fields + requires valid AccountData payload for updates
  * Other actions - Adds error indicating invalid action for account context

  ## Examples

      iex> attrs = %{
      ...>   action: :create_account,
      ...>   instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   source: "test",
      ...>   source_idempk: "123",
      ...>   payload: %{name: "Test", type: :asset, currency: "USD"}
      ...> }
      iex> changeset = DoubleEntryLedger.Event.AccountEventMap.changeset(%DoubleEntryLedger.Event.AccountEventMap{}, attrs)
      iex> changeset.valid?
      true

      iex> update_attrs = %{
      ...>   action: :update_account,
      ...>   instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   source: "test",
      ...>   source_idempk: "123",
      ...>   update_idempk: "upd_456",
      ...>   payload: %{description: "Updated Test Account"}
      ...> }
      iex> changeset = DoubleEntryLedger.Event.AccountEventMap.changeset(%DoubleEntryLedger.Event.AccountEventMap{}, update_attrs)
      iex> changeset.valid?
      true

      iex> invalid_attrs = %{action: :delete_account, source: "test"}
      iex> changeset = DoubleEntryLedger.Event.AccountEventMap.changeset(%DoubleEntryLedger.Event.AccountEventMap{}, invalid_attrs)
      iex> changeset.valid?
      false
      iex> Keyword.has_key?(changeset.errors, :action)
      true
  """
  @spec changeset(t() | map(), map()) :: Changeset.t(AccountEventMap.t())
  def changeset(event_map, attrs) do
    case fetch_action(attrs) do
      :create_account ->
        base_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &AccountData.changeset/2, required: true)

      :update_account ->
        update_changeset(event_map, attrs)
        |> cast_embed(:payload, with: &AccountData.update_changeset/2, required: true)

      val ->
        base_changeset(event_map, attrs)
        |> add_error(:action, "invalid in this context", value: "#{val}")
    end
  end

  @doc """
  Converts an AccountData payload to a plain map representation.

  This function implements the EventMap behavior callback for AccountData payloads.
  It delegates to the `AccountData.to_map/1` function to ensure consistent
  serialization of account data.

  ## Parameters

  * `payload` - The AccountData struct to convert

  ## Returns

  * A map representation of the account data

  ## Examples

      iex> alias DoubleEntryLedger.Event.{AccountEventMap, AccountData}
      iex> payload = %AccountData{name: "Test Account", type: :asset, currency: "USD"}
      iex> map = AccountEventMap.payload_to_map(payload)
      iex> map.name
      "Test Account"
      iex> map.type
      :asset

  ## Implementation Note

  This function is required by the EventMap behavior and is called automatically
  when using `to_map/1` on the complete EventMap struct.
  """
  @impl true
  @spec payload_to_map(AccountData.t()) :: map()
  def payload_to_map(payload), do: AccountData.to_map(payload)
end
