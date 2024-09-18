defmodule DoubleEntryLedger.Instance do
  @moduledoc """
  The `DoubleEntryLedger.Instance` module defines the schema and functions for managing ledger instances.
  A ledger instance represents a collection of accounts and transactions, and includes configuration and metadata.

  ## Schema Fields

    - `id` (binary): The unique identifier for the ledger instance.
    - `config` (map): Configuration settings for the ledger instance.
    - `description` (String.t()): A description of the ledger instance.
    - `metadata` (map): Additional metadata for the ledger instance.
    - `name` (String.t()): The name of the ledger instance.
    - `accounts` ([Account.t()] | Ecto.Association.NotLoaded.t()): The accounts associated with the ledger instance.
    - `transactions` ([Transaction.t()] | Ecto.Association.NotLoaded.t()): The transactions associated with the ledger instance.
    - `inserted_at` (DateTime.t()): The timestamp when the ledger instance was created.
    - `updated_at` (DateTime.t()): The timestamp when the ledger instance was last updated.

  ## Functions

    - `changeset/2`: Creates a changeset for the ledger instance based on the given attributes.
    - `validate_account_balances/1`: Validates that the total debit and credit balances of all accounts in the ledger instance are equal.
    - `ledger_value/1`: Calculates the total posted and pending debit and credit balances for all accounts in the ledger instance.
  """
  use Ecto.Schema
  import Ecto.Changeset

#  alias DoubleEntryLedger.Repo
#  alias __MODULE__, as: Instance

  @type t :: %__MODULE__{
    id: binary() | nil,
    config: map() | nil,
    description: String.t() | nil,
    metadata: map() | nil,
    name: String.t() | nil,
#    accounts: [Account.t()]| Ecto.Association.NotLoaded.t(),
#    transactions: [Transaction.t()] | Ecto.Association.NotLoaded.t(),
    inserted_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "instances" do
    field :config, :map
    field :description, :string
    field :metadata, :map
    field :name, :string
#    has_many :accounts, Account, foreign_key: :ledger_instance_id
#    has_many :transactions, Transaction, foreign_key: :ledger_instance_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(Instance.t(), map()) :: Ecto.Changeset.t()
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :description, :config, :metadata])
    |> validate_required([:name])
  end
end
