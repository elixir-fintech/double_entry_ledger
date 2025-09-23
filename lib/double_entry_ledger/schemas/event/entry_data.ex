defmodule DoubleEntryLedger.Event.EntryData do
  @moduledoc """
  Represents individual transaction entry data for the Double Entry Ledger system.

  This embedded schema contains the essential information needed to record financial
  movements between accounts. It is an abstraction above the actual Entry model and
  it abstracts away the details of the underlying double-entry accounting system that
  uses debit and credit entries.

  The amount represents the value of the transaction in the smallest currency unit. A positive
  amount indicates an addition to the balance of the account, while a negative amount indicates a
  deduction independent of the normal_balance of the affected account.

  ## Fields

  * `account_address`: address of the account involved in the transaction (required)
  * `amount`: Integer amount in the smallest currency unit (e.g., cents) (required)
  * `currency`: The currency of the amount, validated against supported currencies (required)

  ## Usage

  EntryData structs are typically embedded within TransactionData as part of the
  event processing flow:

      entry_data = %EntryData{
        account_address: "cash:user:123",
        amount: 10000,  # $100.00
        currency: :USD
      }

      transaction_data = %TransactionData{
        status: :pending,
        entries: [entry_data, other_entry],
      }

  ## Validation

  The module provides validation to ensure entries contain all required fields
  and that the currency is one of the supported types defined in the Currency module.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.Currency
  alias __MODULE__, as: EntryData

  @currency_atoms Currency.currency_atoms()

  @typedoc """
  Represents the EntryData struct used for transaction entries in the ledger system.

  This type defines the structure of an entry including its account, amount, and currency.
  It's commonly used as a return value and parameter type throughout the Double Entry Ledger API.

  ## Fields

  * `account_address`: The UUID of the account affected by this entry
  * `amount`: Integer amount in the smallest currency unit (e.g., cents)
  * `currency`: Atom representing the currency (e.g., :USD, :EUR)
  """
  @type t :: %EntryData{
          account_address: String.t(),
          amount: integer(),
          currency: Currency.currency_atom()
        }

  @derive {Jason.Encoder, only: [:account_address, :amount, :currency]}

  @primary_key false
  embedded_schema do
    field(:account_address, :string)
    field(:amount, :integer)
    field(:currency, Ecto.Enum, values: @currency_atoms)
  end

  @doc """
  Creates a changeset for validating EntryData attributes.

  This function creates an Ecto changeset that validates the required fields
  for an entry in a transaction, ensuring that account_address, amount, and currency
  are all provided and that the currency is one of the supported types.

  ## Parameters
    - `entry_data`: The EntryData struct to create a changeset for
    - `attrs`: Map of attributes to apply to the struct

  ## Returns
    - An Ecto.Changeset with validations applied

  ## Examples

      iex> alias DoubleEntryLedger.Event.EntryData
      iex> attrs = %{account_address: "cash:user:123", amount: 5000, currency: :USD}
      iex> changeset = EntryData.changeset(%EntryData{}, attrs)
      iex> changeset.valid?
      true

      iex> alias DoubleEntryLedger.Event.EntryData
      iex> attrs = %{amount: 5000} # Missing required fields
      iex> changeset = EntryData.changeset(%EntryData{}, attrs)
      iex> changeset.valid?
      false
  """
  @spec changeset(t() | map(), map()) :: Ecto.Changeset.t()
  def changeset(entry_data, attrs) do
    entry_data
    |> cast(attrs, [:account_address, :amount, :currency])
    |> validate_required([:account_address, :amount, :currency])
    |> validate_format(:account_address, ~r/^[a-zA-Z_0-9]+(:[a-zA-Z_0-9]+){0,}$/, message: "is not a valid account address")
    |> validate_inclusion(:currency, @currency_atoms)
  end

  @doc """
  Converts the given `EntryData.t` struct to a map.

  ## Examples

      iex> alias DoubleEntryLedger.Event.EntryData
      iex> entry_data = %EntryData{}
      iex> EntryData.to_map(entry_data)
      %{account_address: nil, amount: nil, currency: nil}

  """
  @spec to_map(t) :: map()
  def to_map(entry_data) do
    %{
      account_address: Map.get(entry_data, :account_address),
      amount: Map.get(entry_data, :amount),
      currency: Map.get(entry_data, :currency)
    }
  end
end
