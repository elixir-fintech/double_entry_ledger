defmodule DoubleEntryLedger.Event.AccountData do
  @moduledoc """
  Schema for account data payload embedded in events.

  This embedded schema captures the minimal set of attributes required to
  describe an account at the moment an event is recorded. It is used to
  validate and cast incoming payloads.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__, as: AccountData
  alias DoubleEntryLedger.{Currency, Types}

  @typedoc """
  Embedded account data captured with an event.

  Fields:
  - currency: ISO currency code represented as an enum (from Currency.currency_atoms/0)
  - name: Human-readable account name
  - address: Unique account identifier (e.g. "account:main")
  - description: Optional description
  - context: Arbitrary metadata map for additional context
  - normal_balance: Either :debit or :credit (from Types.credit_and_debit/0)
  - type: Account category/type (from Types.account_types/0)
  - allowed_negative: Whether the account is allowed to have a negative balance
  """
  @type t :: %AccountData{
          currency: Currency.currency_atom() | nil,
          name: String.t() | nil,
          address: String.t() | nil,
          description: String.t() | nil,
          context: map() | nil,
          normal_balance: Types.credit_and_debit() | nil,
          type: Types.account_type() | nil,
          allowed_negative: boolean() | nil
        }

  @derive {Jason.Encoder, only: [:name, :address, :currency, :description, :context, :normal_balance, :type, :allowed_negative]}

  @currency_atoms Currency.currency_atoms()
  @credit_and_debit Types.credit_and_debit()
  @account_types Types.account_types()

  @primary_key false
  embedded_schema do
    field(:currency, Ecto.Enum, values: @currency_atoms)
    field(:name, :string)
    field(:address, :string)
    field(:description, :string)
    field(:context, :map)
    field(:normal_balance, Ecto.Enum, values: @credit_and_debit)
    field(:type, Ecto.Enum, values: @account_types)
    field(:allowed_negative, :boolean)
  end

  @doc """
  Builds an Ecto.Changeset for AccountData.

  Casts: [:currency, :address, :name, :description, :context, :normal_balance, :type, :allowed_negative]
  Validates required: [:currency, address, :type]

  ## Examples

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> alias DoubleEntryLedger.Currency
      iex> alias DoubleEntryLedger.Types
      iex> attrs = %{
      ...>   currency: hd(Currency.currency_atoms()),
      ...>   address: "account:main",
      ...>   type: hd(Types.account_types())
      ...> }
      iex> changeset = AccountData.changeset(%AccountData{}, attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> changeset = AccountData.changeset(%AccountData{}, %{})
      iex> changeset.valid?
      false
      iex> required = [:currency, :address, :type]
      iex> required -- Keyword.keys(changeset.errors)
      []
  """
  @spec changeset(AccountData.t(), map()) :: Ecto.Changeset.t()
  def changeset(account_data, attrs) do
    account_data
    |> cast(attrs, [
      :currency,
      :name,
      :address,
      :description,
      :context,
      :normal_balance,
      :type,
      :allowed_negative
    ])
    |> validate_required([:currency, :address, :type])
  end

  @doc """
  Builds an update changeset for AccountData that only allows modification of certain fields.

  Unlike the main changeset, this function only allows updates to fields that are
  safe to modify after account creation: description and context. Critical fields
  like currency, name, and type are not allowed to be updated through this changeset.

  Casts: [:description, :context]
  Validates: No additional validations beyond casting

  ## Parameters

  * `account_data` - The AccountData struct to update
  * `attrs` - Map of attributes to update

  ## Returns

  * `Ecto.Changeset.t()` - Changeset with only update-safe fields cast

  ## Examples

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> existing_data = %AccountData{
      ...>   currency: :USD,
      ...>   address: "account:main",
      ...>   name: "Cash Account",
      ...>   type: :asset,
      ...>   description: "Old description"
      ...> }
      iex> update_attrs = %{
      ...>   description: "Updated description",
      ...>   context: %{department: "finance"}
      ...> }
      iex> changeset = AccountData.update_changeset(existing_data, update_attrs)
      iex> changeset.valid?
      true
      iex> changeset.changes.description
      "Updated description"
      iex> changeset.changes.context
      %{department: "finance"}

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> existing_data = %AccountData{currency: :USD, name: "Cash", type: :asset}
      iex> # Attempting to update restricted fields should have no effect
      iex> invalid_update = %{
      ...>   name: "New Name",
      ...>   address: "account:main2",
      ...>   currency: :EUR,
      ...>   type: :liability,
      ...>   description: "Valid update"
      ...> }
      iex> changeset = AccountData.update_changeset(existing_data, invalid_update)
      iex> changeset.valid?
      true
      iex> # description and name should be in changes, not the restricted fields
      iex> Map.keys(changeset.changes)
      [:description, :name]
      iex> changeset.changes.description
      "Valid update"
  """
  @spec update_changeset(AccountData.t(), map()) :: Ecto.Changeset.t()
  def update_changeset(account_data, attrs) do
    account_data
    |> cast(attrs, [:name, :description, :context])
  end

  @doc """
  Converts an AccountData struct into a plain map with the same fields unless they are nil.

  The resulting map may include these keys:
  :currency, :name, :description, :context, :normal_balance, :type, :allowed_negative

  ## Examples

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> alias DoubleEntryLedger.Currency
      iex> alias DoubleEntryLedger.Types
      iex> data = %AccountData{
      ...>   currency: hd(Currency.currency_atoms()),
      ...>   name: "Cash",
      ...>   type: hd(Types.account_types()),
      ...>   address: "account:main"
      ...> }
      iex> map = AccountData.to_map(data)
      iex> Map.keys(map) |> Enum.sort()
      [:address, :currency, :name, :type]
      iex> map.address == data.address and map.currency == data.currency and map.type == data.type and map.name == "Cash"
      true
  """
  def to_map(%{} = account_data) do
    %{
      currency: Map.get(account_data, :currency),
      name: Map.get(account_data, :name),
      address: Map.get(account_data, :address),
      description: Map.get(account_data, :description),
      context: Map.get(account_data, :context),
      normal_balance: Map.get(account_data, :normal_balance),
      type: Map.get(account_data, :type),
      allowed_negative: Map.get(account_data, :allowed_negative)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  def to_map(_), do: %{}
end
