defmodule DoubleEntryLedger.Types do
  @moduledoc """
  This module defines types used in the DoubleEntryLedger application.
  """

  @credit_and_debit [:credit, :debit]
  @type credit_or_debit :: unquote(Enum.reduce(@credit_and_debit, fn state, acc -> quote do: unquote(state) | unquote(acc) end))
  @type credit_and_debit :: [credit_or_debit]

  @type trx_types :: :posted | :pending | :pending_to_pending | :pending_to_posted | :pending_to_archived

  @spec credit_and_debit() :: credit_and_debit()
  def credit_and_debit, do: @credit_and_debit
end
