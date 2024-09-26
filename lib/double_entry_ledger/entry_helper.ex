alias TransactionStore.Ledger.{Entry, Types }

defprotocol EntryHelper do
  @spec debit_sum(t(), integer()) :: integer()
  @doc """
  Returns the sum of the entries
  """
  def debit_sum(entry, acc)

  @spec credit_sum(t(), integer()) :: integer()
  def credit_sum(entry, acc)

  @spec uuid(t()) :: <<_::128>>
  def uuid(entry)

  @spec currency(t()) :: atom()
  def currency(entry)
end

defimpl EntryHelper, for: Ecto.Changeset do

  @spec debit_sum(Ecto.Changeset.t(), integer()) :: integer()
  def debit_sum(%{changes: %{type: t, amount: a }}, acc) do
    if t == :debit, do: acc + a.amount, else: acc
  end

  @spec credit_sum(Ecto.Changeset.t(), integer()) :: integer()
  def credit_sum(%{changes: %{type: t, amount: a }}, acc) do
    if t == :credit, do: acc + a.amount, else: acc
  end

  @spec uuid(Ecto.Changeset.t()) :: <<_::128>>
  def uuid(%{changes: %{account_id: id}}), do: Ecto.UUID.dump!(id)


  @spec currency(Ecto.Changeset.t()) :: atom()
  def currency(%{changes: %{amount: a}}), do: a.currency
end

defimpl EntryHelper, for: Entry do

  @type c_or_d :: Types.c_or_d()

  @spec debit_sum(Entry.t(), integer()) :: integer()
  def debit_sum(%{type: t, amount: a }, acc) do
    if t == :debit, do: acc + a.amount, else: acc
  end

  @spec credit_sum(Entry.t(), integer()) :: integer()
  def credit_sum(%{type: t, amount: a }, acc) do
    if t == :credit, do: acc + a.amount, else: acc
  end

  @spec uuid(Entry.t()) :: <<_::128>>
  def uuid(%{account_id: id}), do: Ecto.UUID.dump!(id)

  @spec currency(Entry.t()) :: atom()
  def currency(%{amount: a}), do: a.currency
end
