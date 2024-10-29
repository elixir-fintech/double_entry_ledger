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
  alias DoubleEntryLedger.{Entry, Instance, Repo, Types}
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
  @spec changeset(Transaction.t(), map(), Types.trx_types()) :: Ecto.Changeset.t()
  def changeset(%{status: status} = transaction, attrs, transition) when status == :pending do
    transaction_changeset(transaction, attrs)
    |> map_ids_to_entries(attrs, transition)
    |> validate_entries()
    |> validate_accounts()
  end

  def changeset(transaction, %{status: status} = attrs) do
    transaction_changeset(transaction, attrs)
    |> cast_assoc(:entries, with: &Entry.changeset(&1, &2, status))
    |> validate_currency()
    |> validate_entries()
    |> validate_accounts()
  end

  @spec transaction_changeset(Transaction.t(), map()) :: Ecto.Changeset.t()
  defp transaction_changeset(transaction, attrs) do
    transaction
    |> Repo.preload([:instance, entries: :account], force: true)
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:status, @states)
    |> validate_state_transition()
    |> update_posted_at()
  end

  @spec states() :: states()
  def states, do: @states

  defp validate_state_transition(%{data: %{status: now}} = changeset) do
    change = get_change(changeset, :status)
    cond do
      change == :archived && now == nil -> add_error(changeset, :status, "cannot create :archived transactions, must be transitioned from :pending")
      now in [:archived, :posted] -> add_error(changeset, :status, "cannot update when in :#{now} state")
      true -> changeset
    end
  end

  defp validate_entries(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []
    cond do
      Enum.count(entries) < 2 -> add_error(changeset, :entries, "must have at least 2 entries")
      !debit_equals_credit_per_currency(entries) -> add_error(changeset, :entries, "must have equal debit and credit")
      true -> changeset
    end
  end

  defp validate_accounts(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []
    ledger_ids = Repo.all(from a in "accounts", where: a.id in ^account_ids(entries), select: a.instance_id)
      |> Enum.map(&UUID.cast!(&1))
    cond do
      ledger_ids == [] -> add_error(changeset, :entries, "no accounts found")
      Enum.all?(ledger_ids, &(&1 == get_field(changeset, :instance_id))) -> changeset
      true -> add_error(changeset, :entries, "accounts must be on same ledger")
    end
  end

  defp validate_currency(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []
    accounts =
      Repo.all(from a in "accounts",
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

  @spec map_ids_to_entries(Ecto.Changeset.t(), map(), Types.trx_types()) :: Ecto.Changeset.t()
  defp map_ids_to_entries(%{data: %{entries: entries}} = changeset, %{entries: new_entries}, transition) do
    # credo:disable-for-next-line Credo.Check.Refactor.CondStatements
    cond do
      length(new_entries) != length(entries) -> add_error(changeset, :entries, "cannot change number of entries")
      true ->
        updated_entries = match_on_account_id(entries, new_entries, transition)
        put_assoc(changeset, :entries, updated_entries)
    end
  end

  defp map_ids_to_entries(%{data: %{entries: entries}} = changeset, _attrs, transition) do
    updated_entries = Enum.map(entries, fn entry -> Entry.update_changeset(entry, %{}, transition) end)
    put_assoc(changeset, :entries, updated_entries)
  end

  @spec match_on_account_id([Entry.t()], [map()], Types.trx_types()) :: [Ecto.Changeset.t()]
  defp match_on_account_id(entries, new_entries, transition) do
    Enum.map(entries, fn entry ->
      new_entry = Enum.find(new_entries, fn new_entry -> new_entry.account_id == entry.account_id end)
      Entry.update_changeset(entry, Map.put_new(new_entry, :id, entry.id), transition)
    end)
  end

  defp update_posted_at(changeset) do
    status = get_field(changeset, :status)
    if status == :posted do
      put_change(changeset, :posted_at, DateTime.utc_now())
    else
      changeset
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
