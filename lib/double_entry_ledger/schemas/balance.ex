defmodule DoubleEntryLedger.Balance do
  @moduledoc """
  TODO
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__, as: Balance

  @primary_key false
  embedded_schema do
    field :amount, :integer, default: 0
    field :debit, :integer, default: 0
    field :credit, :integer, default: 0
  end

  @type t :: %Balance{
    amount: integer(),
    credit: integer(),
    debit: integer()
  }

  @doc """
  Creates a new balance struct with default values.

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

  ## Parameters

  - `balance` - The balance struct.
  - `attrs` - The attributes to update the balance with.

  ## Examples

      iex> balance = DoubleEntryLedger.Balance.new()
      %DoubleEntryLedger.Balance{amount: 0, credit: 0, debit: 0}
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
  Updates the balance struct and returns the changeset.

  ## Parameters

  - `balance` - The balance struct.
  - `amount` - The amount to update the balance with.
  - `e_type` - The type of the change, which is also entry type.
  - `a_type` - The type of the account the balance belongs to.

  ## Scenarios

  - e_type = a_type: The entry amount is added to the balance struct amount.
  - e_type != a_type: The entry amount is subtracted from the balance struct amount.

  ## Examples

      iex> balance = DoubleEntryLedger.Balance.new()
      %DoubleEntryLedger.Balance{amount: 0, credit: 0, debit: 0}
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.update_balance(balance, 50, :debit, :debit)
      iex> changes
      %{amount: 50, debit: 50}

      iex> balance = DoubleEntryLedger.Balance.new()
      %DoubleEntryLedger.Balance{amount: 0, credit: 0, debit: 0}
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.update_balance(balance, 50, :debit, :credit)
      iex> changes
      %{amount: -50, debit: 50}

  """
  @spec update_balance(Balance.t(), integer(), atom(), atom()) :: Ecto.Changeset.t()
  def update_balance(%{amount: amt } = balance, amount, e_type, a_type) when e_type == a_type do
    balance
    |> change()
    |> put_change(:amount, amt + amount)
    |> put_change(e_type, Map.get(balance, e_type) + amount)
  end

  def update_balance(%{amount: amt } = balance, amount, e_type, a_type) when e_type != a_type do
    balance
    |> change()
    |> put_change(:amount, amt - amount)
    |> put_change(e_type, Map.get(balance, e_type) + amount)
  end

  @doc """
  Reverses the pending balance and returns the changeset.

  ## Parameters

  - `balance` - The balance struct.
  - `amount` - The amount to reverse the balance with.
  - `e_type` - The type of the change, which is also entry type.
  - `a_type` - The type of the account the balance belongs to.

  ## Scenarios
  - e_type = a_type: The entry amount is added to the balance struct amount.
  - e_type != a_type: The entry amount is subtracted from the balance struct amount.

  ## Examples

      iex> balance = DoubleEntryLedger.Balance.new()
      %DoubleEntryLedger.Balance{amount: 0, credit: 0, debit: 0}
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.reverse_pending(balance, 50, :debit, :debit)
      iex> changes
      %{amount: 50, debit: -50}

      iex> balance = DoubleEntryLedger.Balance.new()
      %DoubleEntryLedger.Balance{amount: 0, credit: 0, debit: 0}
      iex> %Ecto.Changeset{valid?: true, changes: changes} = DoubleEntryLedger.Balance.reverse_pending(balance, 50, :credit, :debit)
      iex> changes
      %{amount: -50, credit: -50}

  """
  @spec reverse_pending(Balance.t(), integer(), atom(), atom()) :: Ecto.Changeset.t()
  def reverse_pending(%{amount: amt } = balance, amount, e_type, a_type) when e_type == a_type do
    balance
    |> change()
    |> put_change(:amount, amt + amount)
    |> put_change(e_type, Map.get(balance, e_type) - amount)
  end

  def reverse_pending(%{amount: amt } = balance, amount, e_type, a_type) when e_type != a_type do
    balance
    |> change()
    |> put_change(:amount, amt - amount)
    |> put_change(e_type, Map.get(balance, e_type) - amount)
  end
end
