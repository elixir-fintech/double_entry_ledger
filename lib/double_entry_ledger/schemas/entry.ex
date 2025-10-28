defmodule DoubleEntryLedger.Entry do
  @moduledoc """
  Defines and manages individual financial entries in the Double Entry Ledger system.
  Entries should always be created or updated through an Command to ensure proper handling
  of balance updates and history creation.

  This module represents the fundamental building blocks of transactions in double-entry accounting,
  where each entry affects exactly one account and belongs to exactly one transaction. Entries
  come in two types - debits and credits - and must balance across a transaction.

  ## Key Concepts

  * **Entry Types**: Each entry must be either a `:debit` or `:credit` type
  * **Transaction Relationship**: Entries are always linked to a transaction
  * **Account Relationship**: Each entry affects exactly one account
  * **Balance History**: Creating or updating entries automatically generates balance history records
  * **Currency Matching**: An entry's currency must match its account's currency

  ## Lifecycle

  Entries go through several possible state transitions:
  * `:posted` - Direct posting to an account's finalized balance
  * `:pending` - Creating a hold or authorization
  * `:pending_to_posted` - Converting a pending entry to a posted entry
  * `:pending_to_pending` - Modifying an existing pending entry
  * `:pending_to_archived` - Canceling a pending entry
  The state transition determines how the entry affects the account's balance and what validations are applied.
  The state itself is stored with the transaction, not the entry.

  ## Balance Updates

  When entries are created or modified, the module automatically:
  1. Updates the associated account's balance
  2. Creates a balance history entry to track the change
  3. Validates that the currency matches the account
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{
    Account,
    BalanceHistoryEntry,
    Repo,
    Transaction,
    Types
  }

  alias __MODULE__, as: Entry

  @typedoc """
  Represents a single financial entry in a transaction.

  An entry records a single financial event affecting one account in the ledger.
  It contains the monetary amount, entry type (debit or credit), and relationships
  to both the account it affects and the transaction it belongs to.

  ## Fields

  * `id`: UUID primary key
  * `value`: Money struct containing amount and currency
  * `type`: Either `:debit` or `:credit`
  * `transaction`: Association to the parent transaction
  * `transaction_id`: Foreign key to the transaction
  * `account`: Association to the affected account
  * `account_id`: Foreign key to the account
  * `balance_history_entries`: List of related balance history records
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
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

  schema "entries" do
    field(:value, Money.Ecto.Map.Type)
    field(:type, Ecto.Enum, values: @debit_and_credit)
    belongs_to(:transaction, Transaction)
    belongs_to(:account, Account)
    has_many(:balance_history_entries, BalanceHistoryEntry, on_replace: :delete)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and inserting an entry with transition state.

  This function builds an Ecto changeset for an entry that manages a specific
  transaction state transition, handling account balance updates and history creation.

  ## Parameters

  * `entry` - The Entry struct to create a changeset for
  * `attrs` - Map of attributes to apply to the entry
  * `transition` - The transition state (e.g., `:posted`, `:pending`, `:pending_to_posted`)

  ## Returns

  * An Ecto.Changeset with validations and associations

  ## Account Updates

  When this changeset is applied:
  1. The account balance is updated according to the entry details and transition type
  2. A balance history entry is created to record this change

  ## Validations

  * Required fields: `:type`, `:value`, `:account_id`
  * Entry type must be `:debit` or `:credit`
  * Entry currency must match account currency

  ## Examples

      # Create a posted debit entry
      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> {:ok, instance} = InstanceStore.create(%{address: "Test:Instance"})
      iex> {:ok, account} = AccountStore.create(instance.address, %{name: "Test Account", address: "account:main1", type: :asset, currency: :USD}, "unique_id_123")
      iex> attrs = %{
      ...>   type: :debit,
      ...>   value: %{amount: 10000, currency: :USD},
      ...>   account_id: account.id,
      ...> }
      iex> changeset = Entry.changeset(%Entry{}, attrs, :posted)
      iex> changeset.valid?
      true
  """
  @spec changeset(Entry.t(), map(), Transaction.state()) :: Ecto.Changeset.t()
  def changeset(entry, %{account_id: id} = attrs, transition)
      when transition in @transaction_states do
    entry
    |> Repo.preload([:account, :balance_history_entries], force: true)
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, @debit_and_credit)
    |> put_assoc(:account, Repo.get!(Account, id))
    |> validate_same_account_currency()
    |> put_account_assoc(transition)
    |> put_balance_history_entry_assoc()
  end

  # catch-all clause
  def changeset(entry, attrs, _transition) do
    changeset(entry, attrs)
  end

  @doc """
  Creates a basic changeset for validating an entry without transition management.

  This simplified version validates the entry data but does not handle account
  balance updates or balance history creation. It's typically used for initial
  validation or when working with entries that don't immediately affect accounts.

  ## Parameters

  * `entry` - The Entry struct to create a changeset for
  * `attrs` - Map of attributes to apply to the entry

  ## Returns

  * An Ecto.Changeset with basic validations applied

  ## Validations

  * Required fields: `:type`, `:value`, `:account_id`
  * Entry type must be `:debit` or `:credit`

  ## Examples

      # Create a simple entry changeset
      iex> attrs = %{
      ...>   type: :credit,
      ...>   value: %{amount: 5000, currency: :EUR},
      ...>   account_id: "550e8400-e29b-41d4-a716-446655440000"
      ...> }
      iex> changeset = Entry.changeset(%Entry{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec changeset(Entry.t(), map()) :: Ecto.Changeset.t()
  # catch-all clause
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, @debit_and_credit)
  end

  @doc """
  Creates a changeset for updating an existing entry with transition handling.

  This function builds a changeset specifically for updating the value of an
  existing entry while properly handling account balance updates and history creation.
  It's used when modifying entries that are already associated with transactions.

  ## Parameters

  * `entry` - The Entry struct to update
  * `attrs` - Map of attributes to update on the entry (only `:value` can be updated)
  * `transition` - The transition state (e.g., `:pending_to_posted`, `:pending_to_pending`)

  ## Returns

  * An Ecto.Changeset with validations, preloaded associations, and balance updates

  ## Account Updates

  When this changeset is applied:
  1. The account balance is updated according to the new entry value and transition type
  2. A balance history entry is created to record this change

  ## Validations

  * Required field: `:value`
  * Entry currency must match account currency

  ## Examples

      # Update a pending entry to be posted
      # An entry has to be created first using an event
      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> alias DoubleEntryLedger.Apis.EventApi
      iex> {:ok, instance} = InstanceStore.create(%{address: "instance1"})
      iex> {:ok, account1} = AccountStore.create(instance.address, %{
      ...>    name: "account1", address: "account:main1", type: :asset, currency: :EUR}, "unique_id_123")
      iex> {:ok, account2} = AccountStore.create(instance.address, %{
      ...>    name: "account2", address: "account:main2", type: :liability, currency: :EUR}, "unique_id_456")
      iex> {:ok, _, _} = EventApi.process_from_params(%{"instance_address" => instance.address,
      ...>  "source" => "s1", "source_idempk" => "1", "action" => "create_transaction",
      ...>  "payload" => %{"status" => :pending, "entries" => [
      ...>      %{"account_address" => account1.address, "amount" => 100, "currency" => :EUR},
      ...>      %{"account_address" => account2.address, "amount" => 100, "currency" => :EUR},
      ...>  ]}})
      iex> [entry | _]= Repo.all(Entry)
      iex> attrs = %{value: %{amount: 120, currency: :EUR}}
      iex> changeset = Entry.update_changeset(entry, attrs, :pending_to_posted)
      iex> changeset.valid?
      true
  """
  @spec update_changeset(Entry.t(), map(), Types.trx_types()) :: Ecto.Changeset.t()
  def update_changeset(entry, attrs, transition) do
    entry
    |> Repo.preload([:transaction, :account, :balance_history_entries], force: true)
    |> cast(attrs, [:value])
    |> validate_required([:value])
    |> validate_same_account_currency()
    |> validate_amount_sign(entry, attrs)
    |> put_account_assoc(transition)
    |> put_balance_history_entry_assoc()
  end

  @spec signed_value(Entry.t()) :: integer()
  def signed_value(entry) do
    entry = Repo.preload(entry, :account)

    if entry.account.normal_balance != entry.type do
      -entry.value.amount
    else
      entry.value.amount
    end
  end

  defp put_account_assoc(changeset, transition) do
    account = get_assoc(changeset, :account, :struct)

    put_assoc(
      changeset,
      :account,
      Account.update_balances(account, %{entry: changeset, trx: transition})
    )
  end

  @spec put_balance_history_entry_assoc(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp put_balance_history_entry_assoc(changeset) do
    account_changeset = get_assoc(changeset, :account, :changeset)
    balance_history_entries = get_assoc(changeset, :balance_history_entries, :struct)

    balance_history_entry_changeset =
      BalanceHistoryEntry.build_from_account_changeset(account_changeset)

    # generally not right way to do it, but most entries will have only one balance history entry
    # and this gets around using a multi
    changeset
    |> put_assoc(:balance_history_entries, [
      balance_history_entry_changeset | balance_history_entries
    ])
  end

  @spec validate_same_account_currency(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_same_account_currency(changeset) do
    account = get_assoc(changeset, :account, :struct)
    currency = get_field(changeset, :value).currency

    if account.currency != currency do
      add_error(
        changeset,
        :currency,
        "account (#{account.currency}) must be equal to entry (#{currency})"
      )
    else
      changeset
    end
  end

  defp validate_amount_sign(changeset, %{type: entry_type}, %{type: change_type}) do
    if entry_type != change_type do
      add_error(
        changeset,
        :type,
        "can't change the amount sign"
      )
    else
      changeset
    end
  end

  defp validate_amount_sign(changeset, _, _), do: changeset
end
