defmodule DoubleEntryLedger.Command.AccountCommandMap do
  @moduledoc """
  CommandMap implementation for account-related operations in the Double Entry Ledger system.

  This module provides validation and structure for account create and update commands. It extends
  the base CommandMap functionality with account-specific payload validation using the
  `AccountData` schema.

  ## Purpose

  The AccountCommandMap is responsible for:
  * Validating account creation command data before persistence
  * Ensuring proper structure and required fields for account operations
  * Providing type safety for account-specific payloads
  * Converting account data to serializable map format

  ## Supported Actions

  Currently supports:
  * `:create_account` - Creates a new account in the ledger instance
  * `:update_account` - Updates an existing account's mutable fields

  ## Usage

      # Create a valid account command
      {:ok, command_map} = AccountCommandMap.create(%{
        action: :create_account,
        instance_address: "acme:ledger",
        source: "accounting_system",
        payload: %{
          name: "Cash Account",
          address: "cash:operating",
          type: :asset,
          currency: "USD"
        }
      })

      # Convert to map for serialization
      map_data = AccountCommandMap.to_map(command_map)

  ## Optional Fields

  * `trace_context` - Vendor-neutral distributed tracing context map
    (e.g. `%{"traceparent" => "00-...", "tracestate" => "..."}`). Must be a flat
    string-valued map with at most `:max_trace_context_keys` keys (default 10).

  ## Validation

  The module validates:
  * All command fields (`action`, `instance_address`, and `source`)
  * Action must be `:create_account` or `:update_account`
  * Payload must conform to `AccountData` schema requirements
  * Required payload fields based on account type

  ## Error Handling

      # Invalid action
      {:error, changeset} = AccountCommandMap.create(%{
        action: :invalid_action,
        # ... other fields
      })

      # Missing required fields
      {:error, changeset} = AccountCommandMap.create(%{
        action: :create_account,
        # missing required fields
      })

  ## Type Safety

  The module provides compile-time type checking through:

      @type t :: CommandMap.t(AccountData.t())

  This ensures that the payload is always of type `AccountData.t()`.
  """
  use Ecto.Schema

  import Ecto.Changeset,
    only: [
      cast: 3,
      cast_embed: 3,
      apply_action: 2,
      add_error: 4,
      validate_format: 3,
      validate_required: 2,
      validate_inclusion: 3
    ]

  import DoubleEntryLedger.Utils.Changeset, only: [validate_trace_context: 1]

  import DoubleEntryLedger.Command.Helper,
    only: [
      fetch_action: 1,
      source_regex: 0,
      address_regex: 0
    ]

  alias DoubleEntryLedger.Command.AccountData
  alias Ecto.Changeset

  alias __MODULE__, as: AccountCommandMap

  @derive {Jason.Encoder,
           only: [
             :action,
             :instance_address,
             :account_address,
             :source,
             :payload
           ]}
  @typedoc """
  Type definition for AccountCommandMap struct.

  Represents an CommandMap specifically for account operations with an `AccountData`
  payload. This provides type safety and clear documentation for functions that
  work with account commands.

  ## Usage in Function Signatures

      @spec process_account_command(AccountCommandMap.t()) :: {:ok, Account.t()} | {:error, term()}
      def process_account_command(%AccountCommandMap{} = command_map) do
        # Implementation with type-safe access to AccountData payload
      end

  ## Pattern Matching

      def handle_command(%AccountCommandMap{action: :create_account, payload: payload}) do
        # payload is guaranteed to be AccountData.t()
      end
  """
  @type t() :: %AccountCommandMap{
          action: :create_account | :update_account,
          instance_address: String.t(),
          account_address: String.t() | nil,
          source: String.t(),
          trace_context: map() | nil,
          payload: AccountData.t()
        }

  @actions [:create_account, :update_account]

  @primary_key false
  embedded_schema do
    field(:action, Ecto.Enum, values: @actions)
    field(:instance_address, :string)
    field(:account_address, :string)
    field(:source, :string)
    field(:trace_context, :map)

    embeds_one(:payload, AccountData, on_replace: :delete)
  end

  def actions(), do: @actions

  @doc """
  Creates and validates an AccountCommandMap from the given attributes.

  This is the primary entry point for creating account commands. It performs
  full validation including payload validation and returns either a valid
  CommandMap struct or validation errors.

  ## Parameters

  * `attrs` - Map containing the command attributes including payload data

  ## Returns

  * `{:ok, AccountCommandMap.t()}` - Successfully created and validated command map
  * `{:error, Ecto.Changeset.t()}` - Validation errors

  ## Required Attributes

  * `action` - Must be `:create_account` or `"create_account"`
  * `instance_address` - Address of the ledger instance
  * `source` - String identifier of the external system
  * `payload` - Map containing account data (see `AccountData` for requirements)

  ## Optional Attributes

  * `account_address` - Existing account address, required for updates
  * `trace_context` - Vendor-neutral distributed tracing context

  ## Examples

      iex> attrs = %{
      ...>   action: :create_account,
      ...>   instance_address: "Test:Ledger",
      ...>   source: "web_app",
      ...>   payload: %{
      ...>     name: "Test Account",
      ...>     address: "account:main",
      ...>     type: :asset,
      ...>     currency: "USD"
      ...>   }
      ...> }
      iex> {:ok, command_map} = DoubleEntryLedger.Command.AccountCommandMap.create(attrs)
      iex> command_map.action
      :create_account
      iex> command_map.payload.name
      "Test Account"

  ## Error Examples

      # Invalid action
      iex> attrs = %{action: :invalid_action, source: "test"}
      iex> {:error, changeset} = DoubleEntryLedger.Command.AccountCommandMap.create(attrs)
      iex> changeset.valid?
      false
      iex> changeset.errors[:action]
      {"invalid in this context", [{:value, "invalid_action"}]}
  """
  @spec create(map()) :: {:ok, t()} | {:error, Changeset.t(AccountCommandMap.t())}
  def create(attrs) do
    %AccountCommandMap{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Creates a changeset for AccountCommandMap validation.

  This function handles action-specific validation logic. It validates the base
  CommandMap fields and then applies account-specific payload validation based
  on the action type.

  ## Parameters

  * `command_map` - The AccountCommandMap struct to validate (can be empty for new records)
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
      ...>   instance_address: "Test:Ledger",
      ...>   source: "test",
      ...>   payload: %{name: "Test", address: "account:main", type: :asset, currency: "USD"}
      ...> }
      iex> changeset = DoubleEntryLedger.Command.AccountCommandMap.changeset(%DoubleEntryLedger.Command.AccountCommandMap{}, attrs)
      iex> changeset.valid?
      true

      iex> update_attrs = %{
      ...>   action: :update_account,
      ...>   instance_address: "Test:Ledger",
      ...>   source: "test",
      ...>   account_address: "account:test",
      ...>   payload: %{description: "Updated Test Account"}
      ...> }
      iex> changeset = DoubleEntryLedger.Command.AccountCommandMap.changeset(%DoubleEntryLedger.Command.AccountCommandMap{}, update_attrs)
      iex> changeset.valid?
      true

      iex> invalid_attrs = %{action: :delete_account, source: "test"}
      iex> changeset = DoubleEntryLedger.Command.AccountCommandMap.changeset(%DoubleEntryLedger.Command.AccountCommandMap{}, invalid_attrs)
      iex> changeset.valid?
      false
      iex> Keyword.has_key?(changeset.errors, :action)
      true
  """
  @spec changeset(t() | map(), map()) :: Changeset.t(AccountCommandMap.t())
  def changeset(command_map, attrs) do
    case fetch_action(attrs) do
      :create_account ->
        base_changeset(command_map, attrs)
        |> cast_embed(:payload, with: &AccountData.changeset/2, required: true)

      :update_account ->
        update_changeset(command_map, attrs)
        |> cast_embed(:payload, with: &AccountData.update_changeset/2, required: true)

      val ->
        base_changeset(command_map, attrs)
        |> add_error(:action, "invalid in this context", value: "#{val}")
    end
  end

  def base_changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :action,
      :instance_address,
      :source,
      :trace_context
    ])
    |> validate_required([:action, :instance_address, :source])
    |> validate_format(:source, source_regex())
    |> validate_inclusion(:action, @actions)
    |> validate_trace_context()
  end

  def update_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:account_address])
    |> validate_required([:account_address])
    |> validate_format(:account_address, address_regex())
    |> base_changeset(attrs)
  end

  @spec to_map(struct()) :: map()
  def to_map(command_map) do
    %{
      action: Map.get(command_map, :action),
      instance_address: Map.get(command_map, :instance_address),
      account_address: Map.get(command_map, :account_address),
      source: Map.get(command_map, :source),
      trace_context: Map.get(command_map, :trace_context),
      payload: AccountData.to_map(Map.get(command_map, :payload))
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end
end
