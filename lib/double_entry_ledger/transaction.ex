defmodule DoubleEntryLedger.Transaction do
  @moduledoc """
  The `DoubleEntryLedger.Transaction` module defines the schema and functions for managing transactions within a ledger instance.
  A transaction consists of multiple entries that affect account balances and includes metadata and status information.

  ## Schema Fields

    - `id` (binary): The unique identifier for the transaction.
    - `effective_at` (DateTime.t()): The effective date and time of the transaction.
    - `event_id` (String.t()): An optional event identifier associated with the transaction.
    - `instance` (Instance.t() | Ecto.Association.NotLoaded.t()): The associated ledger instance.
    - `instance_id` (binary): The ID of the associated ledger instance.
    - `metadata` (map): Additional metadata for the transaction.
    - `posted_at` (DateTime.t()): The date and time when the transaction was posted.
    - `status` (:pending | :posted | :archived): The status of the transaction.
    - `entries` ([Entry.t()] | Ecto.Association.NotLoaded.t()): The entries associated with the transaction.
    - `inserted_at` (DateTime.t()): The timestamp when the transaction was created.
    - `updated_at` (DateTime.t()): The timestamp when the transaction was last updated.

  ## Functions

    - `create/1`: Creates a new transaction with associated entries.
    - `update/2`: Updates the status of an existing transaction and its associated entries.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Ecto.UUID
  alias DoubleEntryLedger.{Account, Entry, Instance, Repo, Transaction}
  alias EntryHelper
  alias Ecto.Multi
  alias __MODULE__, as: Transaction

  @type t :: %__MODULE__{
    id: binary() | nil,
    effective_at: DateTime.t() | nil,
    event_id: String.t() | nil,
    instance: Instance.t() | Ecto.Association.NotLoaded.t(),
    instance_id: binary() | nil,
    metadata: map() | nil,
    posted_at: DateTime.t() | nil,
    status: :pending | :posted | :archived | nil,
    entries: [Entry.t()] | Ecto.Association.NotLoaded.t(),
    inserted_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @required_attrs ~w(status effective_at instance_id)a
  @optional_attrs ~w(event_id posted_at metadata)a

  @states [:pending, :posted, :archived]
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transactions" do
    field :effective_at, :utc_datetime_usec, default: DateTime.utc_now
    field :event_id, :string
    field :metadata, :map, default: %{}
    field :posted_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @states
    belongs_to :instance, Instance
    has_many :entries, Entry

    timestamps(type: :utc_datetime_usec)
  end

  @spec create(Transaction.t() | map()) :: Ecto.Multi.t()
  def create(transaction) do
    Multi.new()
    |> Multi.insert(:transaction, changeset(%Transaction{}, transaction))
    |> Multi.run(:entries, fn repo, %{transaction: t} ->
         {:ok, repo.preload(t, [entries: :account], [{:force, true}])}
      end)
    |> Multi.merge(fn %{entries: %{entries: entries}} ->
         Enum.reduce(entries, Multi.new(), fn %{account: account} = entry, multi ->
           multi
           |> Multi.update(
                account.id,
                Account.update_balances(account, %{entry: entry, trx: transaction.status})
              )
         end)
      end)
  end

  @spec update(Transaction.t(), map()) :: Ecto.Multi.t()
  def update(%{status: now } = transaction, %{status: next } = attr) do
    transition = case {now, next } do
      {:pending, :posted } -> :pending_to_posted
      {:pending, :archived } -> :pending_to_archived
      {_, _ } -> now
    end

    Multi.new()
    |> Multi.update(:transaction, changeset(transaction, attr))
    |> Multi.run(:entries, fn repo, %{transaction: t} ->
         {:ok, repo.preload(t, [entries: :account], [{:force, true}])}
      end)
    |> Multi.merge(fn %{entries: %{entries: entries}} ->
         Enum.reduce(entries, Multi.new(), fn %{account: account} = entry, multi ->
           multi
           |> Multi.update(
                account.id,
                Account.update_balances(account, %{entry: entry, trx: transition})
              )
         end)
      end)
  end

  @doc false
  @spec changeset(Transaction.t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, attrs) do
    transaction
    |> Repo.preload([:instance, entries: :account])
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> cast_assoc(:entries, with: &Entry.changeset/2)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:status, [:pending, :posted, :archived])
    |> validate_state_transition()
    |> validate_currency()
    |> validate_entries()
    |> validate_accounts()
  end

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
