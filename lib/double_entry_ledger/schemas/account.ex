defmodule DoubleEntryLedger.Account do
  @moduledoc """
  The `DoubleEntryLedger.Account` module manages account information and balance updates
  within a ledger system. It uses `Ecto.Schema` to define the schema for accounts and provides
  various functions to handle account changesets and balance updates.

  ## Schema Fields

    - `id` (binary): The unique identifier for the account.
    - `currency` (Currency.currency_atom()): The currency type for the account.
    - `description` (string): An optional description of the account.
    - `context` (map): Optional additional context information about the account.
    - `name` (string): The name of the account.
    - `type` (Types.c_or_d()): The type of the account, either `:credit` or `:debit`.
    - `available` (integer): The available balance in the account.
    - `allowed_negative` (boolean): Whether the account can have a negative balance.
    - `posted` (Balance.t()): The posted balance details of the account.
    - `pending` (Balance.t()): The pending balance details of the account.
    - `instance_id` (binary): The ID of the associated ledger instance.
    - `inserted_at` (DateTime): The timestamp when the account was created.
    - `updated_at` (DateTime): The timestamp when the account was last updated.

  ## Functions

    - `changeset/2`: Creates a changeset for the account based on the given attributes.
    - `update_balances/2`: Updates the balances of the account based on the given entry and transaction type.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias DoubleEntryLedger.{
    Balance,
    BalanceHistoryEntry,
    Currency,
    Entry,
    Instance,
    Types}
  alias __MODULE__, as: Account

  @credit_and_debit Types.credit_and_debit()

  @type t :: %Account{
    id: binary() | nil,
    currency: Currency.currency_atom() | nil,
    description: String.t() | nil,
    context: map() | nil,
    name: String.t() | nil,
    type: Types.credit_or_debit() | nil,
    available: integer(),
    allowed_negative: boolean(),
    posted: Balance.t() | nil,
    pending: Balance.t() | nil,
    instance_id: binary() | nil,
    inserted_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @currency_atoms Currency.currency_atoms()

  schema "accounts" do
    field :currency, Ecto.Enum, values: @currency_atoms, default: :EUR
    field :description, :string
    field :context, :map
    field :name, :string
    field :type, Ecto.Enum, values: @credit_and_debit
    field :available, :integer, default: 0
    field :allowed_negative, :boolean, default: true
    field :lock_version, :integer, default: 1

    embeds_one :posted, Balance, on_replace: :delete
    embeds_one :pending, Balance, on_replace: :delete

    belongs_to :instance, Instance

    has_many :entries, Entry, foreign_key: :account_id
    has_many :balance_history_entries, BalanceHistoryEntry,
      foreign_key: :account_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for the account based on the given attributes.

  ## Parameters

    - `account` (Account.t()): The account struct.
    - `attrs` (map): The attributes to be cast to the account.

  """
  @spec changeset(Account.t(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :description, :currency, :type, :context, :allowed_negative, :instance_id])
    |> validate_required([:name, :currency, :type, :instance_id])
    |> validate_inclusion(:type, @credit_and_debit)
    |> validate_inclusion(:currency, @currency_atoms)
    |> cast_embed(:posted, with: &Balance.changeset/2)
    |> cast_embed(:pending, with: &Balance.changeset/2)
  end

  @spec update_balances(Account.t(), %{entry: (Entry.t() | Ecto.Changeset.t()), trx: Types.trx_types()}) :: Ecto.Changeset.t()
  def update_balances(account, %{entry: entry, trx: trx}) when is_struct(entry, Entry)  do
    entry_changeset = Entry.changeset(entry, %{})
    update_balances(account, %{entry: entry_changeset, trx: trx})
  end

  def update_balances(account, %{entry: entry_changeset, trx: trx}) do
    entry_type = get_field(entry_changeset, :type)
    account
    |> change()
    |> validate_entry_changeset(entry_changeset)
    |> update(entry_changeset, entry_type, trx)
    |> update_available()
    |> optimistic_lock(:lock_version)
  end

  defp validate_entry_changeset(%{data: %{id: account_id, currency: currency}} = changeset, entry_changeset) do
    entry_account_id = get_field(entry_changeset, :account_id)
    entry_currency = get_field(entry_changeset, :value).currency
    cond do
      !entry_changeset.valid? -> add_error(changeset, :balance, "can't apply an invalid entry changeset")
      account_id != entry_account_id -> add_error(changeset, :id, "entry account_id (#{entry_account_id}) must be equal to account id (#{account_id})")
      currency != entry_currency -> add_error(changeset, :currency, "entry currency (#{entry_currency}) must be equal to account currency (#{currency})")
      true -> changeset
    end
  end

  @spec update(Ecto.Changeset.t(), Ecto.Changeset.t(), Types.credit_or_debit(), Types.trx_types()) :: Ecto.Changeset.t()
  defp update(%{data: %{posted: po, type: t}} = changeset, entry, entry_type, trx) when trx == :posted do
    entry_value = get_field(entry, :value)
    changeset
    |> put_embed(:posted, Balance.update_balance(po, entry_value.amount, entry_type, t))
  end

  defp update(%{data: %{pending: pe, type: t}} = changeset, entry, entry_type, trx) when trx == :pending and entry_type == t do
    entry_value = get_field(entry, :value)
    changeset
    |> put_embed(:pending, Balance.update_balance(pe, entry_value.amount, entry_type, opposite_direction(entry_type)))
  end

  defp update(%{data: %{pending: pe, type: t}} = changeset, entry, entry_type, trx) when trx == :pending and entry_type != t do
    entry_value = get_field(entry, :value)
    changeset
    |> put_change(:pending, Balance.update_balance(pe, entry_value.amount, entry_type, entry_type))
  end

  defp update(%{data: %{pending: pe, posted: po, type: t }} = changeset, entry, entry_type, trx) when trx == :pending_to_posted do
    new_value = get_field(entry, :value)
    current_value = entry.data.value
    changeset
    |> put_change(:pending, Balance.reverse_pending(pe, current_value.amount, entry_type, t))
    |> put_change(:posted, Balance.update_balance(po, new_value.amount, entry_type, t))
  end

  defp update(%{data: %{pending: pe, type: t }} = changeset, entry, entry_type, trx) when trx == :pending_to_pending do
    new_value = get_field(entry, :value)
    current_value = entry.data.value
    changeset
    |> put_change(:pending, Balance.reverse_and_update_pending(pe, current_value.amount, new_value.amount, entry_type, t))
  end

  defp update(%{data: %{pending: pe, type: t}} = changeset, entry, entry_type, trx) when trx == :pending_to_archived do
    entry_value = get_field(entry, :value)
    changeset
    |> put_change(:pending, Balance.reverse_pending(pe, entry_value.amount, entry_type, t))
  end

  # catch-all clause
  defp update(changeset, _, _, transition), do: add_error(changeset, :entry, "invalid transition: #{transition}")

  @spec update_available(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp update_available(%{data: %{allowed_negative: allowed_negative, type: type } } = changeset) do
    pending = fetch_field!(changeset, :pending)
    %{amount: amount } = fetch_field!(changeset, :posted)
    available = amount - Map.fetch!(pending, opposite_direction(type))
    case !allowed_negative && available < 0  do
      true -> add_error(changeset, :available, "amount can't be negative")
      false -> put_change(changeset, :available, max(0, available))
    end
  end

  @spec opposite_direction(Types.credit_or_debit()) :: Types.credit_or_debit()
  defp opposite_direction(direction) do
    if direction == :debit, do: :credit, else: :debit
  end
end
