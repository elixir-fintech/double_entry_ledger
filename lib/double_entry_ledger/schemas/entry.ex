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

  @type t :: %Entry{
    id: Ecto.UUID.t() | nil,
    value: Money.t() | nil,
    type: Types.credit_or_debit() | nil,
    transaction: Transaction.t() | Ecto.Association.NotLoaded.t(),
    transaction_id: Ecto.UUID.t() | nil,
    account: Account.t() | Ecto.Association.NotLoaded.t(),
    account_id: Ecto.UUID.t() | nil,
    inserted_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @debit_and_credit Types.credit_and_debit()
  @transaction_states Transaction.states()

  @required_attrs ~w(type value account_id)a
  @optional_attrs ~w(transaction_id)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "entries" do
    field :value, Money.Ecto.Composite.Type
    field :type, Ecto.Enum, values: @debit_and_credit
    belongs_to :transaction, Transaction
    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(Entry.t(), map(), Transaction.state()) :: Ecto.Changeset.t()
  def changeset(entry, %{account_id: id} = attrs, transition) when transition in @transaction_states do
    entry
    |> Repo.preload([:account], force: true)
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, @debit_and_credit)
    |> put_assoc(:account, Repo.get!(Account, id))
    |> put_account_assoc(transition)
  end

  def changeset(entry, attrs, _transition) do # catch-all clause
    changeset(entry, attrs)
  end

  @spec changeset(Entry.t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do # catch-all clause
    entry
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, @debit_and_credit)
  end

  @spec update_changeset(Entry.t(), map(), Types.trx_types()) :: Ecto.Changeset.t()
  def update_changeset(entry, attrs, transition) do
    entry
    |> Repo.preload([:transaction, :account], force: true)
    |> cast(attrs, [:value])
    |> validate_required([:value])
    |> validate_same_account_currency()
    |> put_account_assoc(transition)
  end

  defp put_account_assoc(changeset, transition) do
    account = get_assoc(changeset, :account, :struct)
    put_assoc(
      changeset,
      :account,
      Account.update_balances(account, %{entry: changeset, trx: transition})
    )
  end

  defp validate_same_account_currency(changeset) do
    account = get_assoc(changeset, :account, :struct)
    currency = get_field(changeset, :value).currency
    if account.currency != currency do
      add_error(
        changeset,
        :account,
        "currency (#{account.currency}) must be equal to entry currency (#{currency})"
      )
    else
      changeset
    end
  end
end
