alias DoubleEntryLedger.Entry

defprotocol EntryHelper do
  @moduledoc """
  Protocol defining helper functions for entries, such as summing debits and credits,
  retrieving UUIDs, and obtaining the currency.
  """

  @doc """
  Returns the sum of debit entries.
  """
  @spec debit_sum(t(), integer()) :: integer()
  def debit_sum(entry, acc)

  @doc """
  Returns the sum of credit entries.
  """
  @spec credit_sum(t(), integer()) :: integer()
  def credit_sum(entry, acc)

  @doc """
  Retrieves the UUID of the entry.
  """
  @spec uuid(t()) :: String.t()
  def uuid(entry)

  @doc """
  Retrieves the currency of the entry.
  """
  @spec currency(t()) :: atom()
  def currency(entry)
end

defimpl EntryHelper, for: Ecto.Changeset do
  @moduledoc """
  Implementation of `EntryHelper` protocol for `Ecto.Changeset`.
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

defimpl EntryHelper, for: Entry do
  @moduledoc """
  Implementation of `EntryHelper` protocol for `Entry` structs.
  """

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
  # def uuid(%{account_id: id}), do: Ecto.UUID.dump!(id)
  def uuid(%{account_id: id}), do: id

  @doc """
  Retrieves the currency from the `Entry`.
  """
  @spec currency(Entry.t()) :: atom()
  def currency(%{value: v}), do: v.currency
end
