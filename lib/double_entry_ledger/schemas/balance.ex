defmodule DoubleEntryLedger.Balance do
  @moduledoc """
  Represents account balance components in the Double Entry Ledger system.

  This module provides an embedded schema for tracking account balances with separate
  debit and credit components, along with the calculated net amount. It enables proper
  double-entry accounting operations by maintaining both sides of the ledger.

  ## Structure

  Balance contains three key fields:
  * `amount`: The net balance
  * `debit`: The cumulative debit entries
  * `credit`: The cumulative credit entries

  ## Usage

  Balance structs are typically embedded within Account records to track both posted
  (finalized) and pending balances separately. They're updated through transactions
  following double-entry accounting principles where:

  * For accounts with normal debit balance (assets, expenses):
    - Debits increase the account balance
    - Credits decrease the account balance

  * For accounts with normal credit balance (liabilities, equity, revenue):
    - Credits increase the account balance
    - Debits decrease the account balance

  ## Key Functions

  * `new/0` - Creates a new Balance struct with zeroed fields
  * `update_balance/4` - Updates a balance based on entry type and account type
  * `reverse_pending/4` - Reverses a pending entry's effect on the balance
  * `reverse_and_update_pending/5` - Combination of reversing and applying a new pending amount
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__, as: Balance

  @primary_key false
  embedded_schema do
    field(:amount, :integer, default: 0)
    field(:debit, :integer, default: 0)
    field(:credit, :integer, default: 0)
  end

  @typedoc """
  Represents the balance components of an account.

  This structure maintains both the separate debit and credit sides of an account's
  balance, as well as the calculated net amount following accounting standards.

  ## Fields

  * `amount`: The net balance
  * `debit`: The cumulative sum of debit entries
  * `credit`: The cumulative sum of credit entries

  This structure is used for both posted (finalized) and pending balances.
  """
  @type t :: %Balance{
          amount: integer(),
          credit: integer(),
          debit: integer()
        }

  @doc """
  Creates a new balance struct with default values of zero.

  This function initializes a Balance struct with all fields set to zero,
  suitable for new accounts or for resetting balances.

  ## Returns

  * A new Balance struct with zeroed fields

  ## Examples

      iex> DoubleEntryLedger.Balance.new()
      %DoubleEntryLedger.Balance{amount: 0, credit: 0, debit: 0}
  """
  @spec new() :: Balance.t()
  def new do
    %__MODULE__{
      amount: 0,
      debit: 0,
      credit: 0
    }
  end

  @doc """
  Builds and returns a changeset for the balance struct.

  Creates an Ecto changeset to validate and prepare balance data for
  database operations. This is typically used when embedding balance
  data within an account record.

  ## Parameters

  * `balance` - The balance struct to modify
  * `attrs` - Map of attributes to apply to the balance

  ## Returns

  * An Ecto.Changeset for the balance

  ## Examples

      iex> balance = DoubleEntryLedger.Balance.new()
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.changeset(balance, %{amount: 100, debit: 100})
      iex> changes
      %{amount: 100, debit: 100}
  """
  @spec changeset(Balance.t(), map()) :: Ecto.Changeset.t()
  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:amount, :debit, :credit])
  end

  @doc """
  Updates a balance based on an entry and account type.

  This function handles the core accounting logic of how entries affect balances
  differently based on the entry type (debit/credit) and the account type.

  ## Parameters

  * `balance` - The balance struct to update
  * `amount` - The amount to apply to the balance
  * `e_type` - The type of entry (:debit or :credit)
  * `a_type` - The normal balance type of the account (:debit or :credit)

  ## Returns

  * An Ecto.Changeset with updated balance values

  ## Accounting Logic

  * When entry type matches account's normal balance type:
    - The amount increases the balance
    - The corresponding debit/credit side increases

  * When entry type is opposite account's normal balance type:
    - The amount decreases the balance
    - The corresponding debit/credit side still increases

  ## Examples

      iex> balance = DoubleEntryLedger.Balance.new()
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.update_balance(balance, 50, :debit, :debit)
      iex> changes
      %{amount: 50, debit: 50}

      iex> balance = DoubleEntryLedger.Balance.new()
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.update_balance(balance, 50, :debit, :credit)
      iex> changes
      %{amount: -50, debit: 50}
  """
  @spec update_balance(Balance.t(), integer(), atom(), atom()) :: Ecto.Changeset.t()
  def update_balance(%{amount: amt} = balance, amount, e_type, a_type) when e_type == a_type do
    balance
    |> change()
    |> put_change(:amount, amt + amount)
    |> put_change(e_type, Map.get(balance, e_type) + amount)
  end

  def update_balance(%{amount: amt} = balance, amount, e_type, a_type) when e_type != a_type do
    balance
    |> change()
    |> put_change(:amount, amt - amount)
    |> put_change(e_type, Map.get(balance, e_type) + amount)
  end

  @doc """
  Reverses the effect of a pending entry on a balance.

  This function is used when canceling or removing pending entries
  from an account's balance. It performs the opposite operation of
  `update_balance/4`.

  ## Parameters

  * `balance` - The balance struct to update
  * `amount` - The amount to reverse from the balance
  * `e_type` - The type of entry being reversed (:debit or :credit)
  * `a_type` - The normal balance type of the account (:debit or :credit)

  ## Returns

  * An Ecto.Changeset with updated balance values

  ## Examples

      iex> balance = DoubleEntryLedger.Balance.new()
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.reverse_pending(balance, 50, :debit, :debit)
      iex> changes
      %{amount: 50, debit: -50}

      iex> balance = DoubleEntryLedger.Balance.new()
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.reverse_pending(balance, 50, :credit, :debit)
      iex> changes
      %{amount: -50, credit: -50}
  """
  @spec reverse_pending(Balance.t(), integer(), atom(), atom()) :: Ecto.Changeset.t()
  def reverse_pending(%{amount: amt} = balance, amount, e_type, a_type) when e_type == a_type do
    balance
    |> change()
    |> put_change(:amount, amt + amount)
    |> put_change(e_type, Map.get(balance, e_type) - amount)
  end

  def reverse_pending(%{amount: amt} = balance, amount, e_type, a_type) when e_type != a_type do
    balance
    |> change()
    |> put_change(:amount, amt - amount)
    |> put_change(e_type, Map.get(balance, e_type) - amount)
  end

  @doc """
  Reverses a pending amount and applies a new amount in a single operation.

  This function is used when updating pending entries to a different amount,
  such as when modifying a hold or authorization. It first reverses the
  original amount and then applies the new amount.

  ## Parameters

  * `balance` - The balance struct to update
  * `amount_to_reverse` - The original amount to reverse
  * `new_amount` - The new amount to apply
  * `e_type` - The type of entry (:debit or :credit)
  * `a_type` - The normal balance type of the account (:debit or :credit)

  ## Returns

  * An Ecto.Changeset with updated balance values

  ## Examples

      iex> balance = %DoubleEntryLedger.Balance{amount: 50, debit: 50, credit: 0}
      iex> %Ecto.Changeset{changes: changes} = DoubleEntryLedger.Balance.reverse_and_update_pending(balance, 50, 75, :debit, :debit)
      iex> changes
      %{amount: 25, debit: 75}

      iex> balance = %DoubleEntryLedger.Balance{amount: -50, credit: 50, debit: 0}
      iex> %Ecto.Changeset{changes: changes} = DoubleEntryLedger.Balance.reverse_and_update_pending(balance, 50, 75, :credit, :debit)
      iex> changes
      %{amount: -25, credit: 75}
  """
  @spec reverse_and_update_pending(Balance.t(), integer(), integer(), atom(), atom()) ::
          Ecto.Changeset.t()
  def reverse_and_update_pending(
        %{amount: amt} = balance,
        amount_to_reverse,
        new_amount,
        e_type,
        a_type
      )
      when e_type == a_type do
    balance
    |> change()
    |> put_change(:amount, amt + amount_to_reverse - new_amount)
    |> put_change(e_type, Map.get(balance, e_type) - amount_to_reverse + new_amount)
  end

  def reverse_and_update_pending(
        %{amount: amt} = balance,
        amount_to_reverse,
        new_amount,
        e_type,
        a_type
      )
      when e_type != a_type do
    balance
    |> change()
    |> put_change(:amount, amt - amount_to_reverse + new_amount)
    |> put_change(e_type, Map.get(balance, e_type) - amount_to_reverse + new_amount)
  end
end
