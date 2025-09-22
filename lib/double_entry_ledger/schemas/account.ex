defmodule DoubleEntryLedger.Account do
  @moduledoc """
  Manages financial accounts in the Double Entry Ledger system.

  This module defines the Account schema and provides functions for account creation,
  updates, and balance management following double-entry bookkeeping principles.

  ## Key Concepts

  * **Normal Balance**: Each account has a default balance direction (debit/credit) based on its type.
    Normal balances are automatically assigned but can be overridden for special cases like contra accounts.
  * **Balance Types**: Accounts track both posted (finalized) and pending balances separately.
  * **Available Balance**: The calculated balance that accounts for both posted transactions
    and pending holds/authorizations.

  ## Schema Fields

  * `id`: UUID primary key
  * `name`: Human-readable account name (required)
  * `description`: Optional text description
  * `currency`: The currency code as an atom (e.g., `:USD`, `:EUR`)
  * `type`: Account classification (`:asset`, `:liability`, `:equity`, `:revenue`, `:expense`)
  * `normal_balance`: Whether the account normally increases with `:debit` or `:credit` entries
  * `available`: Calculated available balance (posted minus relevant pending)
  * `allowed_negative`: Whether the account can have a negative available balance
  * `context`: JSON map for additional metadata
  * `posted`: Embedded Balance struct for settled transactions
  * `pending`: Embedded Balance struct for pending transactions
  * `lock_version`: Integer for optimistic concurrency control
  * `instance_id`: Foreign key to the ledger instance
  * `inserted_at`/`updated_at`: Timestamps

  ## Transaction Processing

  The module handles various transaction types:
  * `:posted` - Direct postings to finalized balance
  * `:pending` - Holds/authorizations for future settlement
  * `:pending_to_posted` - Converting pending entries to posted
  * `:pending_to_pending` - Modifying pending entries
  * `:pending_to_archived` - Removing pending entries

  ## Relationships

  * Belongs to: `instance`
  * Has many: `entries`
  * Has many: `balance_history_entries`
  """
  use DoubleEntryLedger.BaseSchema

  alias Ecto.Changeset

  alias DoubleEntryLedger.{
    Balance,
    BalanceHistoryEntry,
    Currency,
    Entry,
    Event,
    Instance,
    Types,
    EventAccountLink
  }

  alias __MODULE__, as: Account

  @credit_and_debit Types.credit_and_debit()
  @account_types Types.account_types()

  def account_types do
    @account_types
  end

  @typedoc """
  Represents a financial account in the double-entry ledger system.

  An account is the fundamental unit that holds balances and participates in transactions.
  Each account has a type, normal balance direction, and tracks both pending and posted amounts.

  ## Fields

  * `id`: UUID primary key
  * `name`: Account name must unique. Can't be changed after creation
  * `address`: Human-readable account address in the format "abc1:def2:(:[a-zA-Z_0-9]+){0,}" (required)
  * `description`: Optional text description
  * `currency`: Currency code atom (e.g., `:USD`, `:EUR`). Can't be changed after creation
  * `type`: Account classification. Can't be changed after creation
  * `normal_balance`: Default balance direction. Can't be changed after creation
  * `available`: Calculated available balance
  * `allowed_negative`: Whether negative balances are allowed
  * `context`: Additional metadata as a map
  * `posted`: Balance struct for posted transactions
  * `pending`: Balance struct for pending transactions
  * `lock_version`: Version for optimistic concurrency control
  * `instance_id`: Reference to ledger instance
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
  @type t :: %Account{
          id: binary() | nil,
          currency: Currency.currency_atom() | nil,
          description: String.t() | nil,
          address: String.t() | nil,
          context: map() | nil,
          name: String.t() | nil,
          normal_balance: Types.credit_or_debit() | nil,
          type: Types.account_type() | nil,
          allowed_negative: boolean(),
          available: integer(),
          posted: Balance.t() | nil,
          pending: Balance.t() | nil,
          lock_version: integer(),
          instance_id: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @currency_atoms Currency.currency_atoms()

  schema "accounts" do
    field(:currency, Ecto.Enum, values: @currency_atoms)
    field(:description, :string)
    field(:address, :string)
    field(:context, :map)
    field(:name, :string)
    field(:normal_balance, Ecto.Enum, values: @credit_and_debit)
    field(:type, Ecto.Enum, values: @account_types)
    field(:allowed_negative, :boolean, default: false)
    field(:available, :integer, default: 0)

    embeds_one(:posted, Balance, on_replace: :delete)
    embeds_one(:pending, Balance, on_replace: :delete)

    belongs_to(:instance, Instance)

    has_many(:entries, Entry, foreign_key: :account_id)
    has_many(:balance_history_entries, BalanceHistoryEntry, foreign_key: :account_id)
    has_many(:event_account_links, EventAccountLink, foreign_key: :account_id)
    many_to_many(:events, Event, join_through: EventAccountLink)

    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and creating a new Account.

  Enforces required fields, validates types, and automatically sets the normal_balance
  based on the account type if not explicitly provided.

  ## Parameters

  * `account` - The account struct to create a changeset for
  * `attrs` - Map of attributes to apply to the account

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Create a valid asset account
      iex> changeset = Account.changeset(%Account{}, %{
      ...>   name: "Cash Account",
      ...>   address: "cash:main:1",
      ...>   currency: :USD,
      ...>   instance_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   type: :asset
      ...> })
      iex> changeset.valid?
      true
      iex> Ecto.Changeset.get_field(changeset, :normal_balance)
      :debit

      # Invalid without required fields
      iex> changeset = Account.changeset(%Account{}, %{})
      iex> changeset.valid?
      false
      iex> MapSet.new(Keyword.keys(changeset.errors))
      MapSet.new([:name, :currency, :address, :instance_id, :type])
  """
  @spec changeset(Account.t(), map()) :: Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :name,
      :address,
      :description,
      :currency,
      :normal_balance,
      :type,
      :context,
      :allowed_negative,
      :instance_id
    ])
    |> validate_required([:name, :address, :currency, :instance_id, :type])
    |> validate_format(:address, ~r/^[a-zA-Z_0-9]+(:[a-zA-Z_0-9]+){0,}$/, message: "is not a valid address")
    |> validate_inclusion(:type, @account_types)
    |> set_normal_balance_based_on_type()
    |> validate_inclusion(:normal_balance, @credit_and_debit)
    |> validate_inclusion(:currency, @currency_atoms)
    |> cast_embed(:posted, with: &Balance.changeset/2)
    |> cast_embed(:pending, with: &Balance.changeset/2)
    |> trim_name()
    |> unique_constraint(:name, name: "unique_instance_name")
    |> unique_constraint(:address, name: :unique_address, message: "has already been taken")
  end

  @doc """
  Creates a changeset for updating an existing Account.

  Limited to updating only the `description`, and `context` fields,
  protecting critical fields like type and currency from modification.

  ## Parameters

  * `account` - The account struct to update
  * `attrs` - Map of attributes to update

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Update account description
      iex> account = %Account{description: "Old Description", instance_id: "inst-123"}
      iex> changeset = Account.update_changeset(account, %{
      ...>   description: "Updated Description"
      ...> })
      iex> changeset.valid?
      true
      iex> Ecto.Changeset.get_change(changeset, :description)
      "Updated Description"
  """
  @spec update_changeset(Account.t(), map()) :: Changeset.t()
  def update_changeset(account, attrs) do
    account
    |> cast(attrs, [:description, :context])
  end

  @doc """
  Creates a changeset for safely deleting an account.

  Validates that there are no associated entries (transactions) before deletion,
  ensuring accounting integrity is maintained.

  ## Parameters

  * `account` - The account to delete

  ## Returns

  * An Ecto.Changeset that will fail if the account has entries

  ## Examples

      # Attempt to delete an account with no entries
      iex> alias DoubleEntryLedger.{InstanceStore, AccountStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "instance1"})
      iex> {:ok, account} = AccountStore.create(%{
      ...>    name: "account1", address: "cash:main:1", instance_id: instance.id, type: :asset, currency: :EUR})
      iex> {:ok, %{id: account_id}} = Repo.delete(Account.delete_changeset(account))
      iex> account.id == account_id
      true

      # Attempt to delete an account with entries
      # This is a database constraint error, not a changeset error
      iex> alias DoubleEntryLedger.{InstanceStore, AccountStore, EventStore}
      iex> {:ok, instance} = InstanceStore.create(%{address: "instance1"})
      iex> {:ok, account1} = AccountStore.create(%{
      ...>    name: "account1", address: "cash:main:1", instance_id: instance.id, type: :asset, currency: :EUR})
      iex> {:ok, account2} = AccountStore.create(%{
      ...>    name: "account2", address: "cash:main:2", instance_id: instance.id, type: :liability, currency: :EUR})
      iex> {:ok, _, _} = EventStore.process_from_event_params(%{"instance_address" => instance.address,
      ...>  "source" => "s1", "source_idempk" => "1", "action" => "create_transaction",
      ...>  "payload" => %{"status" => "pending", "entries" => [
      ...>      %{"account_id" => account1.id, "amount" => 100, "currency" => "EUR"},
      ...>      %{"account_id" => account2.id, "amount" => 100, "currency" => "EUR"},
      ...>  ]}})
      iex> {:error, changeset} = Account.delete_changeset(account1)
      ...> |> Repo.delete()
      iex> [entries: {"are still associated with this entry", _}] = changeset.errors
  """
  @spec delete_changeset(Account.t()) :: Changeset.t()
  def delete_changeset(account) do
    account
    |> change()
    |> no_assoc_constraint(:entries)
  end

  @doc """
  Updates account balances based on an entry and transaction type.

  This function handles all the complex account balance updates for different
  transaction scenarios like posting, pending holds, and settlement.

  ## Parameters

  * `account` - The account to update
  * `params` - Map containing:
    * `entry` - Entry struct or changeset with the transaction details
    * `trx` - Transaction type (`:posted`, `:pending`, `:pending_to_posted`, etc.)

  ## Returns

  * A changeset with updated balance fields and optimistic lock version increment

  ## Implementation Notes

  * Validates that entry and account currencies match
  * Handles various transaction types with different balance update logic
  * Enforces non-negative balance if `allowed_negative` is false
  * Uses optimistic locking to prevent concurrent balance modifications

  ## Transaction Types

  * `:posted` - Direct posting to finalized balance
  * `:pending` - Holds/authorizations for future settlement
  * `:pending_to_posted` - Converting pending entries to posted
  * `:pending_to_pending` - Modifying existing pending entries
  * `:pending_to_archived` - Removing pending entries without posting
  """
  @spec update_balances(Account.t(), %{
          entry: Entry.t() | Changeset.t(),
          trx: Types.trx_types()
        }) :: Changeset.t()
  def update_balances(account, %{entry: entry, trx: trx}) when is_struct(entry, Entry) do
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

  # if the normal_balance is already set, do nothing. This allows for the setup of accounts with a specific normal_balance
  # such as contra accounts and similar
  @spec set_normal_balance_based_on_type(Changeset.t()) :: Changeset.t()
  defp set_normal_balance_based_on_type(%{changes: %{normal_balance: nb}} = changeset)
       when nb in @credit_and_debit do
    changeset
  end

  defp set_normal_balance_based_on_type(changeset) do
    type = get_field(changeset, :type)

    normal_balance =
      case type do
        :asset -> :debit
        :expense -> :debit
        :liability -> :credit
        :equity -> :credit
        :revenue -> :credit
        _ -> nil
      end

    if normal_balance != nil do
      put_change(changeset, :normal_balance, normal_balance)
    else
      add_error(changeset, :type, "invalid account type: #{type}")
    end
  end

  @spec validate_entry_changeset(Changeset.t(), Changeset.t()) :: Changeset.t()
  defp validate_entry_changeset(
         %{data: %{id: account_id, currency: currency}} = changeset,
         entry_changeset
       ) do
    entry_account_id = get_field(entry_changeset, :account_id)
    entry_currency = get_field(entry_changeset, :value).currency

    cond do
      !entry_changeset.valid? ->
        add_error(changeset, :balance, "can't apply an invalid entry changeset")

      account_id != entry_account_id ->
        add_error(
          changeset,
          :id,
          "entry account_id (#{entry_account_id}) must be equal to account id (#{account_id})"
        )

      currency != entry_currency ->
        add_error(
          changeset,
          :currency,
          "entry currency (#{entry_currency}) must be equal to account currency (#{currency})"
        )

      true ->
        changeset
    end
  end

  @spec update(Changeset.t(), Changeset.t(), Types.credit_or_debit(), Types.trx_types()) ::
          Ecto.Changeset.t()
  defp update(%{data: %{posted: po, normal_balance: nb}} = changeset, entry, entry_type, trx)
       when trx == :posted do
    entry_value = get_field(entry, :value)

    changeset
    |> put_embed(:posted, Balance.update_balance(po, entry_value.amount, entry_type, nb))
  end

  defp update(%{data: %{pending: pe, normal_balance: nb}} = changeset, entry, entry_type, trx)
       when trx == :pending do
    entry_value = get_field(entry, :value)

    changeset
    |> put_embed(
      :pending,
      Balance.update_balance(pe, entry_value.amount, entry_type, nb)
    )
  end

  defp update(
         %{data: %{pending: pe, posted: po, normal_balance: nb}} = changeset,
         entry,
         entry_type,
         trx
       )
       when trx == :pending_to_posted do
    new_value = get_field(entry, :value)
    current_value = entry.data.value

    changeset
    |> put_change(:pending, Balance.reverse_pending(pe, current_value.amount, entry_type, nb))
    |> put_change(:posted, Balance.update_balance(po, new_value.amount, entry_type, nb))
  end

  defp update(%{data: %{pending: pe, normal_balance: nb}} = changeset, entry, entry_type, trx)
       when trx == :pending_to_pending do
    new_value = get_field(entry, :value)
    current_value = entry.data.value

    changeset
    |> put_change(
      :pending,
      Balance.reverse_and_update_pending(
        pe,
        current_value.amount,
        new_value.amount,
        entry_type,
        nb
      )
    )
  end

  defp update(%{data: %{pending: pe, normal_balance: nb}} = changeset, entry, entry_type, trx)
       when trx == :pending_to_archived do
    entry_value = get_field(entry, :value)

    changeset
    |> put_change(:pending, Balance.reverse_pending(pe, entry_value.amount, entry_type, nb))
  end

  # catch-all clause
  defp update(changeset, _, _, transition),
    do: add_error(changeset, :entry, "invalid transition: #{transition}")

  @spec update_available(Changeset.t()) :: Changeset.t()
  defp update_available(
         %{data: %{allowed_negative: allowed_negative, normal_balance: nb}} = changeset
       ) do
    pending = fetch_field!(changeset, :pending)
    %{amount: amount} = fetch_field!(changeset, :posted)
    available = amount - Map.fetch!(pending, opposite_direction(nb))

    case !allowed_negative && available < 0 do
      true -> add_error(changeset, :available, "amount can't be negative")
      false -> put_change(changeset, :available, max(0, available))
    end
  end

  @spec opposite_direction(Types.credit_or_debit()) :: Types.credit_or_debit()
  defp opposite_direction(direction) do
    if direction == :debit, do: :credit, else: :debit
  end

  defp trim_name(changeset) do
    update_change(changeset, :name, &String.trim/1)
  end
end
