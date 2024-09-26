defmodule DoubleEntryLedger.Entry do
  @moduledoc """
  The `DoubleEntryLedger.Entry` module defines the schema and functions for managing entries
  in the ledger. An entry affects exactly one ledger account and is linked to exactly one transaction.
  A transaction must have at least 2 entries to be valid, with equal debit and credit entries.

  ## Schema Fields

    - `id` (binary): The unique identifier for the entry.
    - `amount` (Money.t()): The monetary amount of the entry.
    - `type` (Types.c_or_d()): The type of the entry, either `:debit` or `:credit`.
    - `transaction_id` (binary): The ID of the associated transaction.
    - `account` (Account.t() | Ecto.Association.NotLoaded.t()): The associated account.
    - `account_id` (binary): The ID of the associated account.
    - `inserted_at` (DateTime.t()): The timestamp when the entry was created.
    - `updated_at` (DateTime.t()): The timestamp when the entry was last updated.

  ## Functions

    - `changeset/2`: Creates a changeset for the entry based on the given attribute
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias DoubleEntryLedger.{Account, Repo, Transaction, Types}
  alias __MODULE__, as: Entry

  @type t :: %__MODULE__{
    id: binary() | nil,
    amount: Money.t(),
    type: Types.c_or_d(),
    transaction: Transaction.t() | Ecto.Association.NotLoaded.t(),
    transaction_id: binary() | nil,
    account: Account.t() | Ecto.Association.NotLoaded.t(),
    account_id: binary(),
    inserted_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @required_attrs ~w(type amount account_id)a
  @optional_attrs ~w(transaction_id)a
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "entries" do
    field :amount, Money.Ecto.Composite.Type
    field :type, Ecto.Enum, values: [:debit, :credit]
    belongs_to :transaction, Transaction
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(Entry.t(), map()) :: Ecto.Changeset.t()
  @doc false
  def changeset(entry, attrs) do
    entry
    |> Repo.preload([:transaction, :account])
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, [:debit, :credit])
  end
end
