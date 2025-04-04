defmodule DoubleEntryLedger.Event.EntryData do
  @moduledoc """
    EntryData for the Transaction payload
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.Currency
  alias __MODULE__, as: EntryData

  @currency_atoms Currency.currency_atoms()

  @type t :: %EntryData{
          account_id: Ecto.UUID.t(),
          amount: integer(),
          currency: Currency.currency_atom()
        }

  @derive {Jason.Encoder, only: [:account_id, :amount, :currency]}

  @primary_key false
  embedded_schema do
    field(:account_id, Ecto.UUID)
    field(:amount, :integer)
    field(:currency, Ecto.Enum, values: @currency_atoms)
  end

  @doc false
  def changeset(entry_data, attrs) do
    entry_data
    |> cast(attrs, [:account_id, :amount, :currency])
    |> validate_required([:account_id, :amount, :currency])
    |> validate_inclusion(:currency, @currency_atoms)
  end

  @doc """
  Converts the given `EntryData.t` struct to a map.

  ## Examples

      iex> alias DoubleEntryLedger.Event.EntryData
      iex> entry_data = %EntryData{}
      iex> EntryData.to_map(entry_data)
      %{account_id: nil, amount: nil, currency: nil}

  """
  @spec to_map(t) :: map()
  def to_map(entry_data) do
    %{
      account_id: entry_data.account_id,
      amount: entry_data.amount,
      currency: entry_data.currency
    }
  end
end
