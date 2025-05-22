defmodule DoubleEntryLedger.Transaction do
  @moduledoc """
  Defines the transaction schema for the double-entry ledger system.

  A transaction represents a financial event recorded in the ledger, consisting of
  multiple balanced entries that affect account balances. Transactions follow double-entry
  accounting principles, ensuring that debits equal credits for each currency involved.

  Transactions can exist in one of three states:
  - `:pending` - Initial state, can be modified
  - `:posted` - Finalized state, cannot be modified
  - `:archived` - Historical state, cannot be modified

  Each transaction belongs to a specific ledger instance and contains at least two entries
  to maintain the balanced equation of accounting.

  The following validations are enforced:
  - Transactions must have at least 2 entries
  - All entries must belong to accounts in the same ledger instance
  - Debits must equal credits for each currency involved
  - State transitions must follow allowed paths
  - Transactions can only be created in the `:pending` or `:posted` state
  - Transactions can only be updated if they are in the `:pending` state
  - Transactions can only be archived from the `:pending` state
  - Transactions can only be posted from the `:pending` state
  - Transactions cannot be modified once posted or archived

  Usage Details:
  Transactions should not be created directly. Instead, use the `DoubleEntryLedger.EventStore` module
  to create events that will generate transactions. The `EventWorker` will handle the processing of these events
  and the creation of transactions in the ledger.
  """

  use DoubleEntryLedger.BaseSchema
  import Ecto.Query, only: [from: 2]

  alias DoubleEntryLedger.{Account, Entry, Event, EventTransactionLink, Instance, Repo, Types}
  alias __MODULE__, as: Transaction

  @states [:pending, :posted, :archived]

  @typedoc """
  Represents the possible states of a transaction:
  - `:pending` - Transaction is in draft mode and can be modified
  - `:posted` - Transaction has been finalized and cannot be changed
  - `:archived` - Transaction has been archived for historical purposes
  """
  @type state ::
          unquote(
            Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )

  @typedoc """
  List of all possible transaction states.
  """
  @type states :: [state]

  @typedoc """
  The transaction struct representing a financial event in the ledger.

  Contains the following fields:
  - `id`: Unique identifier
  - `instance`: Associated ledger instance
  - `instance_id`: ID of the associated ledger instance
  - `posted_at`: Timestamp when the transaction was posted
  - `status`: Current state of the transaction
  - `entries`: Associated debit/credit entries
  - `inserted_at`: Creation timestamp
  - `updated_at`: Last modification timestamp
  """
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          posted_at: DateTime.t() | nil,
          status: state() | nil,
          entries: [Entry.t()] | Ecto.Association.NotLoaded.t(),
          event_transaction_links: [EventTransactionLink.t()] | Ecto.Association.NotLoaded.t(),
          events: [Event.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @required_attrs ~w(status instance_id)a

  schema "transactions" do
    field(:posted_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: @states)
    belongs_to(:instance, Instance)
    has_many(:entries, Entry)
    has_many(:event_transaction_links, EventTransactionLink)
    has_many(:events, through: [:event_transaction_links, :event])

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for updating a pending transaction.

  This function is specifically for updating transactions in the `:pending` state,
  allowing for controlled transitions between states.

  ## Parameters
    - `transaction`: The existing transaction struct
    - `attrs`: Map of attributes to change
    - `transition`: The transaction type being applied

  ## Returns
    An `Ecto.Changeset` with validations applied
  """
  @spec changeset(Transaction.t(), map(), Types.trx_types()) :: Ecto.Changeset.t()
  def changeset(%{status: status} = transaction, attrs, transition) when status == :pending do
    transaction_changeset(transaction, attrs)
    |> map_ids_to_entries(attrs, transition)
    |> validate_entry_count()
    |> validate_accounts()
    |> validate_debit_equals_credit_per_currency()
  end

  @doc """
  Creates a changeset for a transaction with the provided attributes.

  Performs validations to ensure the transaction follows double-entry accounting principles:
  - Has at least two entries
  - All entries belong to accounts in the same ledger instance
  - Debits equal credits for each currency involved
  - State transitions follow allowed paths

  ## Parameters
    - `transaction`: The existing transaction struct
    - `attrs`: Map of attributes to change

  ## Returns
    An `Ecto.Changeset` with validations applied
  """
  @spec changeset(Transaction.t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, %{status: status} = attrs) do
    transaction_changeset(transaction, attrs)
    |> cast_assoc(:entries, with: &Entry.changeset(&1, &2, status))
    |> validate_entry_count()
    |> validate_accounts()
    |> validate_debit_equals_credit_per_currency()
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

  @doc """
  Returns the list of all valid transaction states.

  ## Returns
    A list of atoms representing the possible transaction states:
    - `:pending`
    - `:posted`
    - `:archived`
  """
  @spec states() :: states()
  def states, do: @states

  @spec validate_state_transition(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_state_transition(%{data: %{status: now}} = changeset) do
    change = get_change(changeset, :status)

    cond do
      change == :archived && now == nil ->
        add_error(
          changeset,
          :status,
          "cannot create :archived transactions, must be transitioned from :pending"
        )

      now in [:archived, :posted] ->
        add_error(changeset, :status, "cannot update when in :#{now} state")

      true ->
        changeset
    end
  end

  @spec validate_entry_count(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_entry_count(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []

    cond do
      entries == [] ->
        add_error(changeset, :entry_count, "must have at least 2 entries")

      Enum.count(entries) == 1 ->
        add_error(changeset, :entry_count, "must have at least 2 entries")
        # added for transfer to EventMap
        |> add_errors_to_entries(:account_id, "at least 2 accounts are required")

      true ->
        changeset
    end
  end

  @spec validate_debit_equals_credit_per_currency(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_debit_equals_credit_per_currency(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []

    if debit_equals_credit_per_currency(entries) == false do
      add_errors_to_entries(changeset, :value, "must have equal debit and credit")
      # added for transfer to EventMap
      |> add_errors_to_entries(:amount, "must have equal debit and credit")
    else
      changeset
    end
  end

  @spec validate_accounts(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_accounts(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []

    ledger_ids =
      Repo.all(from(a in Account, where: a.id in ^account_ids(entries), select: a.instance_id))

    cond do
      ledger_ids == [] ->
        add_errors_to_entries(changeset, :account_id, "no accounts found")

      Enum.all?(ledger_ids, &(&1 == get_field(changeset, :instance_id))) ->
        changeset

      true ->
        add_errors_to_entries(changeset, :account_id, "accounts must be on same ledger")
    end
  end

  @spec map_ids_to_entries(Ecto.Changeset.t(), map(), Types.trx_types()) :: Ecto.Changeset.t()
  defp map_ids_to_entries(
         %{data: %{entries: entries}} = changeset,
         %{entries: new_entries},
         transition
       ) do
    if length(new_entries) != length(entries) do
      add_error(changeset, :entry_count, "cannot change number of entries")
    else
      updated_entries = match_on_account_id(entries, new_entries, transition)
      put_assoc(changeset, :entries, updated_entries)
    end
  end

  defp map_ids_to_entries(%{data: %{entries: entries}} = changeset, _attrs, transition) do
    updated_entries =
      Enum.map(entries, fn entry -> Entry.update_changeset(entry, %{}, transition) end)

    put_assoc(changeset, :entries, updated_entries)
  end

  @spec match_on_account_id([Entry.t()], [map()], Types.trx_types()) :: [Ecto.Changeset.t()]
  defp match_on_account_id(entries, new_entries, transition) do
    Enum.map(entries, fn entry ->
      new_entry =
        Enum.find(new_entries, fn new_entry -> new_entry.account_id == entry.account_id end)

      Entry.update_changeset(entry, Map.put_new(new_entry, :id, entry.id), transition)
    end)
  end

  @spec update_posted_at(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp update_posted_at(changeset) do
    status = get_field(changeset, :status)

    if status == :posted do
      put_change(changeset, :posted_at, DateTime.utc_now())
    else
      changeset
    end
  end

  @spec debit_equals_credit_per_currency([Entry.t()]) :: boolean()
  defp debit_equals_credit_per_currency(entries) do
    Enum.group_by(entries, &DoubleEntryLedger.EntryHelper.currency(&1))
    |> Enum.map(fn {_currency, entries} -> debit_sum(entries) == credit_sum(entries) end)
    |> Enum.all?(& &1)
  end

  @spec add_errors_to_entries(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  defp add_errors_to_entries(changeset, field, error) do
    (get_assoc(changeset, :entries, :changeset) || [])
    |> Enum.map(&add_error(&1, field, error))
    |> then(&put_assoc(changeset, :entries, &1))
  end

  @spec account_ids([Entry.t() | Ecto.Changeset.t()]) :: [Ecto.UUID.t()]
  defp account_ids(entries), do: Enum.map(entries, &DoubleEntryLedger.EntryHelper.uuid(&1))

  @spec debit_sum([Entry.t() | Ecto.Changeset.t()]) :: integer()
  defp debit_sum(entries),
    do: Enum.reduce(entries, 0, &DoubleEntryLedger.EntryHelper.debit_sum(&1, &2))

  @spec credit_sum([Entry.t() | Ecto.Changeset.t()]) :: integer()
  defp credit_sum(entries),
    do: Enum.reduce(entries, 0, &DoubleEntryLedger.EntryHelper.credit_sum(&1, &2))
end
