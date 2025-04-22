defmodule DoubleEntryLedger.BalanceHistoryEntry do
  @moduledoc """
  Tracks historical balance states for accounts in the Double Entry Ledger system.

  This module defines the BalanceHistoryEntry schema, which creates an immutable
  record of an account's balance at specific points in time. These entries are
  created automatically whenever an account balance changes, typically due to
  transactions being posted or settled.

  ## Purpose

  Balance history entries serve several important purposes:

  * **Audit Trail**: They provide a complete history of balance changes for auditing
  * **Reconciliation**: They enable verification and reconciliation of account balances
  * **Reporting**: They support point-in-time reporting and historical analysis
  * **Debugging**: They help diagnose issues by showing exactly when balances changed

  ## Structure

  Each BalanceHistoryEntry contains:

  * References to both the affected account and the entry that caused the change
  * A snapshot of the account's posted balance
  * A snapshot of the account's pending balance
  * The calculated available balance at that moment

  Balance history entries are immutable and append-only, creating a reliable
  chronological record of all balance changes in the system.
  """
  use DoubleEntryLedger.BaseSchema
  alias Ecto.Changeset
  alias DoubleEntryLedger.{Account, Entry, Balance}
  alias __MODULE__, as: BalanceHistoryEntry

  @typedoc """
  Represents a historical record of an account's balance at a specific point in time.

  When an entry affects an account balance, a BalanceHistoryEntry is created to
  preserve the account's state after that change, including both posted and pending
  balances and the calculated available amount.

  ## Fields

  * `id`: UUID primary key
  * `posted`: Embedded Balance struct capturing posted transactions
  * `pending`: Embedded Balance struct capturing pending transactions
  * `available`: Calculated available balance
  * `account`: Association to the related account
  * `account_id`: Foreign key to the account
  * `entry`: Association to the entry that caused the change
  * `entry_id`: Foreign key to the entry
  * `inserted_at`: Timestamp when the record was created
  * `updated_at`: Timestamp when the record was last updated
  """
  @type t :: %BalanceHistoryEntry{
          id: Ecto.UUID.t(),
          posted: Balance.t(),
          pending: Balance.t(),
          available: integer(),
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          account_id: Ecto.UUID.t(),
          entry: Entry.t() | Ecto.Association.NotLoaded.t(),
          entry_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "balance_history_entries" do
    field(:available, :integer, default: 0)

    embeds_one(:posted, Balance, on_replace: :delete)
    embeds_one(:pending, Balance, on_replace: :delete)

    belongs_to(:account, Account)
    belongs_to(:entry, Entry)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a balance history entry from an account changeset.

  This function extracts the relevant balance information from an account changeset
  and creates a new BalanceHistoryEntry changeset. It's typically called automatically
  whenever an account's balance is updated through a transaction.

  ## Parameters

  * `account_changeset` - Ecto.Changeset containing the updated account data

  ## Returns

  * An Ecto.Changeset for a new BalanceHistoryEntry

  ## Examples

      iex> alias DoubleEntryLedger.{Account, Balance, BalanceHistoryEntry}
      iex> account = %Account{
      ...>   id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   available: 500,
      ...>   posted: %Balance{debit: 1000, credit: 500},
      ...>   pending: %Balance{debit: 0, credit: 0}
      ...> }
      iex> account_changeset = Ecto.Changeset.change(account)
      iex> changeset = BalanceHistoryEntry.build_from_account_changeset(account_changeset)
      iex> changeset.valid?
      true
      iex> Ecto.Changeset.get_field(changeset, :account_id)
      "550e8400-e29b-41d4-a716-446655440000"
  """
  @spec build_from_account_changeset(Changeset.t()) :: Changeset.t()
  def build_from_account_changeset(account_changeset) do
    %BalanceHistoryEntry{}
    |> cast(
      %{
        account_id: get_field(account_changeset, :id),
        available: get_field(account_changeset, :available)
      },
      [:available, :account_id]
    )
    |> put_embed(
      :posted,
      Balance.changeset(
        %Balance{},
        Map.from_struct(get_embed(account_changeset, :posted, :struct))
      )
    )
    |> put_embed(
      :pending,
      Balance.changeset(
        %Balance{},
        Map.from_struct(get_embed(account_changeset, :pending, :struct))
      )
    )
  end
end
