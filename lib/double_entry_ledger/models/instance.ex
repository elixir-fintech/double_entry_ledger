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

  alias DoubleEntryLedger.{Account, Repo, Transaction}
  alias __MODULE__, as: Instance

  @type t :: %__MODULE__{
    id: binary() | nil,
    config: map() | nil,
    description: String.t() | nil,
    metadata: map() | nil,
    name: String.t() | nil,
    accounts: [Account.t()]| Ecto.Association.NotLoaded.t(),
    transactions: [Transaction.t()] | Ecto.Association.NotLoaded.t(),
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
    has_many :accounts, Account, foreign_key: :instance_id
    has_many :transactions, Transaction, foreign_key: :instance_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(Instance.t(), map()) :: Ecto.Changeset.t()
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :description, :config, :metadata])
    |> validate_required([:name])
  end

  @doc """
  Validates that the total debit and credit balances of all accounts in the ledger instance are equal.

  ## Parameters

    - `instance` (Instance.t()): The ledger instance struct.

  ## Returns

    - `{:ok, map()}`: If the debit and credit balances are equal.
    - `{:error, String.t()}`: If the debit and credit balances are not equal.

  """
  @spec validate_account_balances(Instance.t()) :: {:ok, map()} | {:error, String.t()}
  def validate_account_balances(instance) do
    instance
    |> ledger_value()
    |> validate_equality()
  end

  @doc """
  Calculates the total posted and pending debit and credit balances for all accounts in the ledger instance.

  ## Parameters

    - `instance` (Instance.t()): The ledger instance struct.

  ## Returns

    - `map()`: A map containing the total posted and pending debit and credit balances.

  """
  @spec ledger_value(Instance.t()) :: map()
  def ledger_value(instance) do
    acc = %{posted_debit: 0, posted_credit: 0, pending_debit: 0, pending_credit: 0}
    instance
    |> Repo.preload([:accounts])
    |> Map.get(:accounts)
    |> Enum.reduce(acc, fn account, acc ->
      acc
      |> Map.update!(:posted_debit, &(&1 + account.posted.debit))
      |> Map.update!(:posted_credit, &(&1 + account.posted.credit))
      |> Map.update!(:pending_debit, &(&1 + account.pending.debit))
      |> Map.update!(:pending_credit, &(&1 + account.pending.credit))
    end)

  end

  defp validate_equality(%{posted_debit: pod, posted_credit: poc, pending_debit: pdd, pending_credit: pdc} = value) do
    if pod == poc and pdd == pdc do
        {:ok, value }
    else
        {:error, "Debit and Credit are not equal"}
    end
  end
end
