defprotocol DoubleEntryLedger.Entryable do
  @moduledoc """
  Protocol defining helper functions for working with entry data in the Double Entry Ledger system.

  This protocol provides a consistent interface for operations on different entry types,
  allowing the same functions to work with both persisted `Entry` structs and entries still
  in `Ecto.Changeset` form. It abstracts away implementation details so that higher-level
  accounting logic can focus on business rules rather than data structure concerns.

  ## Key Functions

  * `debit_sum/2` - Accumulates the sum of debit entries
  * `credit_sum/2` - Accumulates the sum of credit entries
  * `uuid/1` - Retrieves the account UUID associated with the entry
  * `currency/1` - Retrieves the currency of the entry

  ## Implementations

  The protocol is implemented for:

  * `Entry` - For working with persisted entry records
  * `Ecto.Changeset` - For working with entries still being validated

  ## Usage Examples

  The protocol enables generic functions that can operate on collections of mixed entry types:

  ```elixir
  defmodule DoubleEntryLedger.TransactionValidator do
    alias DoubleEntryLedger.Entryable

    # Works with both Entry structs and changesets
    def balance_entries?(entries) do
      debit_sum = Enum.reduce(entries, 0, &Entryable.debit_sum/2)
      credit_sum = Enum.reduce(entries, 0, &Entryable.credit_sum/2)
      debit_sum == credit_sum
    end

    # Group entries by currency
    def group_by_currency(entries) do
      Enum.group_by(entries, &Entryable.currency/1)
    end
  end
  ```

  """

  @doc """
  Returns the sum of debit entries.

  Accumulates the amount of entries with type `:debit` into the accumulator.

  ## Examples

      # Using with Entry struct
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> debit_entry = %Entry{type: :debit, value: %{amount: 500, currency: :USD}}
      iex> Entryable.debit_sum(debit_entry, 100)
      600
      iex> credit_entry = %Entry{type: :credit, value: %{amount: 500, currency: :USD}}
      iex> Entryable.debit_sum(credit_entry, 100)
      100

      # Using with Changeset
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> alias Ecto.Changeset
      iex> changeset = Changeset.change(%Entry{}, %{type: :debit, value: %{amount: 500, currency: :USD}})
      iex> Entryable.debit_sum(changeset, 100)
      600
  """
  @spec debit_sum(t(), integer()) :: integer()
  def debit_sum(entry, acc)

  @doc """
  Returns the sum of credit entries.

  Accumulates the amount of entries with type `:credit` into the accumulator.

  ## Examples

      # Using with Entry struct
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> credit_entry = %Entry{type: :credit, value: %{amount: 500, currency: :USD}}
      iex> Entryable.credit_sum(credit_entry, 100)
      600
      iex> debit_entry = %Entry{type: :debit, value: %{amount: 500, currency: :USD}}
      iex> Entryable.credit_sum(debit_entry, 100)
      100

      # Using with Changeset
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> alias Ecto.Changeset
      iex> changeset = Changeset.change(%Entry{}, %{type: :credit, value: %{amount: 500, currency: :USD}})
      iex> Entryable.credit_sum(changeset, 100)
      600
  """
  @spec credit_sum(t(), integer()) :: integer()
  def credit_sum(entry, acc)

  @doc """
  Retrieves the UUID of the entry.

  ## Examples

      # Using with Entry struct
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> entry = %Entry{account_id: "550e8400-e29b-41d4-a716-446655440000"}
      iex> Entryable.uuid(entry)
      "550e8400-e29b-41d4-a716-446655440000"

      # Using with Changeset
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> alias Ecto.Changeset
      iex> changeset = Changeset.change(%Entry{}, %{account_id: "550e8400-e29b-41d4-a716-446655440000"})
      iex> Entryable.uuid(changeset)
      "550e8400-e29b-41d4-a716-446655440000"
  """
  @spec uuid(t()) :: String.t()
  def uuid(entry)

  @doc """
  Retrieves the currency of the entry.

  ## Examples

      # Using with Entry struct
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> entry = %Entry{value: %{amount: 500, currency: :USD}}
      iex> Entryable.currency(entry)
      :USD

      # Using with Changeset
      iex> alias DoubleEntryLedger.Entry
      iex> alias DoubleEntryLedger.Entryable
      iex> alias Ecto.Changeset
      iex> changeset = Changeset.change(%Entry{}, %{value: %{amount: 500, currency: :USD}})
      iex> Entryable.currency(changeset)
      :USD
  """
  @spec currency(t()) :: atom()
  def currency(entry)
end

defimpl DoubleEntryLedger.Entryable, for: Ecto.Changeset do
  @moduledoc """
  Implementation of `DoubleEntryLedger.Entryable` protocol for `Ecto.Changeset`.

  This implementation enables protocol functions to work with entries that are still
  being validated or constructed via Ecto changesets. It extracts relevant data from
  the changeset's changes map to provide the same interface as persisted entries.
  """

  @doc """
  Returns the sum of debit entries for an `Ecto.Changeset`.
  """
  @spec debit_sum(Ecto.Changeset.t(), integer()) :: integer()
  def debit_sum(%{changes: %{type: t, value: v}}, acc) do
    if t == :debit, do: acc + v.amount, else: acc
  end

  @doc """
  Returns the sum of credit entries for an `Ecto.Changeset`.
  """
  @spec credit_sum(Ecto.Changeset.t(), integer()) :: integer()
  def credit_sum(%{changes: %{type: t, value: v}}, acc) do
    if t == :credit, do: acc + v.amount, else: acc
  end

  @doc """
  Retrieves the UUID from the `Ecto.Changeset`.
  """
  @spec uuid(Ecto.Changeset.t()) :: String.t()
  def uuid(%{changes: %{account_id: id}}), do: id

  @doc """
  Retrieves the currency from the `Ecto.Changeset`.
  """
  @spec currency(Ecto.Changeset.t()) :: atom()
  def currency(%{changes: %{value: v}}), do: v.currency
end

defimpl DoubleEntryLedger.Entryable, for: DoubleEntryLedger.Entry do
  @moduledoc """
  Implementation of `DoubleEntryLedger.Entryable` protocol for `Entry` structs.

  This implementation works with fully persisted and loaded Entry structs from the database.
  It provides direct access to entry fields like type, account_id and value fields.
  """
  alias DoubleEntryLedger.Entry

  @doc """
  Returns the sum of debit entries for an `Entry`.
  """
  @spec debit_sum(Entry.t(), integer()) :: integer()
  def debit_sum(%{type: t, value: v}, acc) do
    if t == :debit, do: acc + v.amount, else: acc
  end

  @doc """
  Returns the sum of credit entries for an `Entry`.
  """
  @spec credit_sum(Entry.t(), integer()) :: integer()
  def credit_sum(%{type: t, value: v}, acc) do
    if t == :credit, do: acc + v.amount, else: acc
  end

  @doc """
  Retrieves the UUID from the `Entry`.
  """
  @spec uuid(Entry.t()) :: String.t()
  def uuid(%{account_id: id}), do: id

  @doc """
  Retrieves the currency from the `Entry`.
  """
  @spec currency(Entry.t()) :: atom()
  def currency(%{value: v}), do: v.currency
end
