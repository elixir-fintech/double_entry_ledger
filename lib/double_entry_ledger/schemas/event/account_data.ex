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
  - description: Optional description
  - context: Arbitrary metadata map for additional context
  - normal_balance: Either :debit or :credit (from Types.credit_and_debit/0)
  - type: Account category/type (from Types.account_types/0)
  - allowed_negative: Whether the account is allowed to have a negative balance
  """
  @type t :: %AccountData{
          currency: Currency.currency_atom() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          context: map() | nil,
          normal_balance: Types.credit_and_debit() | nil,
          type: Types.account_type() | nil,
          allowed_negative: boolean()
        }

  @currency_atoms Currency.currency_atoms()
  @credit_and_debit Types.credit_and_debit()
  @account_types Types.account_types()

  @primary_key false
  embedded_schema do
    field(:currency, Ecto.Enum, values: @currency_atoms)
    field(:name, :string)
    field(:description, :string)
    field(:context, :map)
    field(:normal_balance, Ecto.Enum, values: @credit_and_debit)
    field(:type, Ecto.Enum, values: @account_types)
    field(:allowed_negative, :boolean, default: false)
  end

  @doc """
  Builds an Ecto.Changeset for AccountData.

  Casts: [:currency, :name, :description, :context, :normal_balance, :type, :allowed_negative]
  Validates required: [:currency, :name, :type]

  ## Examples

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> alias DoubleEntryLedger.Currency
      iex> alias DoubleEntryLedger.Types
      iex> attrs = %{
      ...>   currency: hd(Currency.currency_atoms()),
      ...>   name: "Cash",
      ...>   type: hd(Types.account_types())
      ...> }
      iex> changeset = AccountData.changeset(%AccountData{}, attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> changeset = AccountData.changeset(%AccountData{}, %{})
      iex> changeset.valid?
      false
      iex> required = [:currency, :name, :type]
      iex> required -- Keyword.keys(changeset.errors)
      []
  """
  @spec changeset(AccountData.t(), map()) :: Ecto.Changeset.t()
  def changeset(account_data, attrs) do
    account_data
    |> cast(attrs, [
      :currency,
      :name,
      :description,
      :context,
      :normal_balance,
      :type,
      :allowed_negative
    ])
    |> validate_required([:currency, :name, :type])
  end

  @doc """
  Converts an AccountData struct into a plain map with the same fields.

  The resulting map includes these keys:
  :currency, :name, :description, :context, :normal_balance, :type, :allowed_negative

  ## Examples

      iex> alias DoubleEntryLedger.Event.AccountData
      iex> alias DoubleEntryLedger.Currency
      iex> alias DoubleEntryLedger.Types
      iex> data = %AccountData{
      ...>   currency: hd(Currency.currency_atoms()),
      ...>   name: "Cash",
      ...>   type: hd(Types.account_types())
      ...> }
      iex> map = AccountData.to_map(data)
      iex> Map.keys(map) |> Enum.sort()
      [:allowed_negative, :context, :currency, :description, :name, :normal_balance, :type]
      iex> map.currency == data.currency and map.type == data.type and map.name == "Cash"
      true
  """
  def to_map(account_data) do
    %{
      currency: account_data.currency,
      name: account_data.name,
      description: account_data.description,
      context: account_data.context,
      normal_balance: account_data.normal_balance,
      type: account_data.type,
      allowed_negative: account_data.allowed_negative
    }
  end
end
