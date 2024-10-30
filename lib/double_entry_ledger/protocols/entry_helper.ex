alias DoubleEntryLedger.Entry

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
  def debit_sum(%{changes: %{type: t, value: v }}, acc) do
    if t == :debit, do: acc + v.amount, else: acc
  end

  @spec credit_sum(Ecto.Changeset.t(), integer()) :: integer()
  def credit_sum(%{changes: %{type: t, value: v }}, acc) do
    if t == :credit, do: acc + v.amount, else: acc
  end

  @spec uuid(Ecto.Changeset.t()) :: <<_::128>>
  def uuid(%{changes: %{account_id: id}}), do: Ecto.UUID.dump!(id)


  @spec currency(Ecto.Changeset.t()) :: atom()
  def currency(%{changes: %{value: v}}), do: v.currency
end

defimpl EntryHelper, for: Entry do

  @spec debit_sum(Entry.t(), integer()) :: integer()
  def debit_sum(%{type: t, value: v }, acc) do
    if t == :debit, do: acc + v.amount, else: acc
  end

  @spec credit_sum(Entry.t(), integer()) :: integer()
  def credit_sum(%{type: t, value: v }, acc) do
    if t == :credit, do: acc + v.amount, else: acc
  end

  @spec uuid(Entry.t()) :: <<_::128>>
  def uuid(%{account_id: id}), do: Ecto.UUID.dump!(id)

  @spec currency(Entry.t()) :: atom()
  def currency(%{value: v}), do: v.currency
end
