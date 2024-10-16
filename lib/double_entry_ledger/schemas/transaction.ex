defmodule DoubleEntryLedger.Transaction do
  @moduledoc """
  The `DoubleEntryLedger.Transaction` module defines the schema and functions for managing transactions within a ledger instance.
  A transaction consists of multiple entries that affect account balances and includes status information.

  ## Schema Fields

    - `id` (binary): The unique identifier for the transaction.
    - `instance` (Instance.t() | Ecto.Association.NotLoaded.t()): The associated ledger instance.
    - `instance_id` (binary): The ID of the associated ledger instance.
    - `posted_at` (DateTime.t()): The date and time when the transaction was posted.
    - `status` (:pending | :posted | :archived): The transaction status.
    - `entries` ([Entry.t()] | Ecto.Association.NotLoaded.t()): The entries associated with the transaction.
    - `inserted_at` (DateTime.t()): The timestamp when the transaction was created.
    - `updated_at` (DateTime.t()): The timestamp when the transaction was last updated.

  ## Functions

    - `states/0`: Returns the list of transaction states.
    - `changeset/2`: Creates and validates the changeset.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Ecto.UUID
  alias DoubleEntryLedger.{Entry, Instance, Repo}
  alias EntryHelper
  alias __MODULE__, as: Transaction

  @states [:pending, :posted, :archived]
  @type state :: unquote(Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end))
  @type states :: [state]

  @type t :: %__MODULE__{
    id: Ecto.UUID.t() | nil,
    instance: Instance.t() | Ecto.Association.NotLoaded.t(),
    instance_id: Ecto.UUID.t() | nil,
    posted_at: DateTime.t() | nil,
    status: state() | nil,
    entries: [Entry.t()] | Ecto.Association.NotLoaded.t(),
    inserted_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @required_attrs ~w(status instance_id)a
  @optional_attrs ~w(posted_at)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transactions" do
    field :posted_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @states
    belongs_to :instance, Instance
    has_many :entries, Entry

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(Transaction.t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, %{} = attrs) do
    transaction
    |> Repo.preload([:instance, entries: :account])
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> cast_assoc(:entries, with: &Entry.changeset/2)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:status, @states)
    |> validate_state_transition()
    |> validate_currency()
    |> validate_entries()
    |> validate_accounts()
  end

  @spec states() :: states()
  def states, do: @states

  defp validate_state_transition(changeset) do
    now = changeset.data.status
    change = get_change(changeset, :status)
    cond do
      now == nil && change in @states -> changeset
      change == nil && now in @states -> changeset
      now == :pending && change in [:posted, :archived] -> changeset
      true -> add_error(changeset, :status, "cannot transition from #{now} to #{change}")
    end
  end

  defp validate_entries(changeset) do
    entries = get_field(changeset, :entries) || []
    cond do
      Enum.count(entries) < 2 -> add_error(changeset, :entries, "must have at least 2 entries")
      !debit_equals_credit_per_currency(entries) -> add_error(changeset, :entries, "must have equal debit and credit")
      true -> changeset
    end
  end

  defp validate_accounts(changeset) do
    entries = get_field(changeset, :entries) || []
    ledger_ids = Repo.all(from a in "accounts", where: a.id in ^account_ids(entries), select: a.instance_id)
      |> Enum.map(&UUID.cast!(&1))
    cond do
      ledger_ids == [] -> add_error(changeset, :entries, "no accounts found")
      Enum.all?(ledger_ids, &(&1 == get_field(changeset, :instance_id))) -> changeset
      true -> add_error(changeset, :entries, "accounts must be on same ledger")
    end
  end

  defp validate_currency(changeset) do
    entries = get_field(changeset, :entries) || []
    accounts = Repo.all(from a in "accounts",
                         where: a.id in ^account_ids(entries),
                         select: [a.id, a.currency ])
               |> Enum.reduce(
                    %{},
                    fn [id, currency], acc -> Map.put(acc, UUID.cast!(id), String.to_atom(currency)) end
                  )
    # credo:disable-for-next-line Credo.Check.Refactor.CondStatements
    cond do
      Enum.all?(entries, &(&1.amount.currency == accounts[&1.account_id])) -> changeset
      true -> add_error(changeset, :entries, "currency must be the same as account")
    end
  end

  defp debit_equals_credit_per_currency(entries) do
    Enum.group_by(entries, &EntryHelper.currency(&1))
        |> Enum.map(fn {_currency, entries} -> debit_sum(entries) == credit_sum(entries) end)
        |> Enum.all?(& &1)
  end

  defp account_ids(entries), do: Enum.map(entries, &EntryHelper.uuid(&1))
  defp debit_sum(entries), do: Enum.reduce(entries, 0, &EntryHelper.debit_sum(&1, &2))
  defp credit_sum(entries), do: Enum.reduce(entries, 0, &EntryHelper.credit_sum(&1, &2))
end
