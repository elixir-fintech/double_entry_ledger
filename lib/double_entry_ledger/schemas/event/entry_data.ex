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

  @primary_key false
  embedded_schema do
    field :account_id, Ecto.UUID
    field :amount, :integer
    field :currency, Ecto.Enum, values: @currency_atoms
  end

  @doc false
  def changeset(entry_data, attrs) do
    entry_data
    |> cast(attrs, [:account_id, :amount, :currency])
    |> validate_required([:account_id, :amount, :currency])
    |> validate_inclusion(:currency, @currency_atoms)
  end
end
