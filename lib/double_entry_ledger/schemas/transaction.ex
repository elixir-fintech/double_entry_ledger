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
  Transactions should not be created directly. Instead, use the `DoubleEntryLedger.Stores.CommandStore` module
  to create commands that will generate transactions. The `CommandWorker` will handle the processing of these commands
  and the creation of transactions in the ledger.
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{
    Entry,
    JournalEvent,
    Instance,
    Types
  }

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
          journal_events: [JournalEvent.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @required_attrs ~w(status instance_id)a

  @derive {
    Flop.Schema,
    filterable: [:status],
    sortable: [:inserted_at, :id],
    default_limit: 40,
    max_limit: 200,
    default_order: %{
      order_by: [:inserted_at, :id],
      order_directions: [:desc, :desc]
    }
  }

  schema "transactions" do
    field(:posted_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: @states)
    belongs_to(:instance, Instance)
    has_many(:entries, Entry)
    has_many(:journal_events, JournalEvent)

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
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:status, @states)
    |> validate_state_transition()
    |> update_posted_at()
  end

  @doc """
  Parent-only changeset for the `insert_all` build path.

  Casts and validates the `Transaction` row's own fields (`status`,
  `instance_id`, etc.) but **does not** `cast_assoc(:entries)`. Entries
  are inserted separately via `Repo.insert_all/3` by the caller.

  The same balance / entry-count / same-ledger invariants that the
  full `changeset/2` enforces via `validate_*` are checked
  independently in the caller (see `Transaction.assert_balanced/1`).
  """
  @spec parent_changeset(Transaction.t(), map()) :: Ecto.Changeset.t()
  def parent_changeset(transaction, attrs) do
    transaction_changeset(transaction, attrs)
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

  @terminal_states [:posted, :archived]

  @doc """
  True when `status` is a terminal state — i.e. the transaction has
  left `:pending` and any associated `pending_transaction_lookup` row
  should be deleted. Both the legacy and batched writers use this to
  decide whether to drop the lookup on an update.
  """
  @spec terminal?(:pending | :posted | :archived) :: boolean()
  def terminal?(status) when status in @terminal_states, do: true
  def terminal?(status) when status in @states, do: false

  @doc """
  Pure invariant: sum of debit amounts equals sum of credit amounts per currency.

  This is the same business rule that
  `validate_debit_equals_credit_per_currency/1` enforces in the
  changeset path, expressed as a plain function on a list of entries.
  Used by the `insert_all` build path to assert the invariant before
  shipping rows to the DB.

  Each entry must expose `:type` (`:debit | :credit`) and a `:value`
  with `:amount` and `:currency`. Both `Money` structs and plain maps
  are accepted as `:value`.

  Returns `:ok` if balanced for every currency, `{:error, :unbalanced}`
  otherwise.

  ## Examples

      iex> entries = [
      ...>   %{type: :debit,  value: %{amount: 100, currency: :USD}},
      ...>   %{type: :credit, value: %{amount: 100, currency: :USD}}
      ...> ]
      iex> DoubleEntryLedger.Transaction.assert_balanced(entries)
      :ok

      iex> entries = [
      ...>   %{type: :debit,  value: %{amount: 100, currency: :USD}},
      ...>   %{type: :credit, value: %{amount:  90, currency: :USD}}
      ...> ]
      iex> DoubleEntryLedger.Transaction.assert_balanced(entries)
      {:error, :unbalanced}

      iex> entries = [
      ...>   %{type: :debit,  value: %{amount: 100, currency: :USD}},
      ...>   %{type: :credit, value: %{amount: 100, currency: :USD}},
      ...>   %{type: :debit,  value: %{amount:  50, currency: :EUR}},
      ...>   %{type: :credit, value: %{amount:  50, currency: :EUR}}
      ...> ]
      iex> DoubleEntryLedger.Transaction.assert_balanced(entries)
      :ok
  """
  @spec assert_balanced([map()]) :: :ok | {:error, :unbalanced}
  def assert_balanced(entries) when is_list(entries) do
    by_currency =
      Enum.reduce(entries, %{}, fn entry, acc ->
        currency = entry.value.currency
        delta = signed_amount(entry)
        Map.update(acc, currency, delta, &(&1 + delta))
      end)

    if Enum.all?(by_currency, fn {_currency, sum} -> sum == 0 end) do
      :ok
    else
      {:error, :unbalanced}
    end
  end

  defp signed_amount(%{type: :debit, value: %{amount: amount}}), do: amount
  defp signed_amount(%{type: :credit, value: %{amount: amount}}), do: -amount

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
        # added for transfer to TransactionCommandMap
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
      # added for transfer to TransactionCommandMap
      |> add_errors_to_entries(:amount, "must have equal debit and credit")
    else
      changeset
    end
  end

  @spec validate_accounts(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_accounts(changeset) do
    entries = get_assoc(changeset, :entries, :struct) || []
    ledger_ids = Enum.map(entries, &entry_instance_id/1)

    cond do
      ledger_ids == [] ->
        add_errors_to_entries(changeset, :account_id, "no accounts found")

      Enum.all?(ledger_ids, &(&1 == get_field(changeset, :instance_id))) ->
        changeset

      true ->
        add_errors_to_entries(changeset, :account_id, "accounts must be on same ledger")
    end
  end

  defp entry_instance_id(%Ecto.Changeset{} = cs), do: get_assoc(cs, :account, :struct).instance_id
  defp entry_instance_id(%{account: account}), do: account.instance_id

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
    Enum.group_by(entries, &DoubleEntryLedger.Entryable.currency(&1))
    |> Enum.map(fn {_currency, entries} -> debit_sum(entries) == credit_sum(entries) end)
    |> Enum.all?(& &1)
  end

  @spec add_errors_to_entries(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  defp add_errors_to_entries(changeset, field, error) do
    (get_assoc(changeset, :entries, :changeset) || [])
    |> Enum.map(&add_error(&1, field, error))
    |> then(&put_assoc(changeset, :entries, &1))
  end

  @spec debit_sum([Entry.t() | Ecto.Changeset.t()]) :: integer()
  defp debit_sum(entries),
    do: Enum.reduce(entries, 0, &DoubleEntryLedger.Entryable.debit_sum(&1, &2))

  @spec credit_sum([Entry.t() | Ecto.Changeset.t()]) :: integer()
  defp credit_sum(entries),
    do: Enum.reduce(entries, 0, &DoubleEntryLedger.Entryable.credit_sum(&1, &2))
end
