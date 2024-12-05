defmodule DoubleEntryLedger.Types do
  @moduledoc """
  This module defines types used in the DoubleEntryLedger application.
  """

  # Define the credit and debit types
  @credit_and_debit [:credit, :debit]
  @type credit_or_debit :: unquote(Enum.reduce(@credit_and_debit, fn state, acc -> quote do: unquote(state) | unquote(acc) end))
  @type credit_and_debit :: [credit_or_debit]

  @spec credit_and_debit() :: credit_and_debit()
  def credit_and_debit, do: @credit_and_debit

  # Define the transaction types
  @type trx_types :: :posted | :pending | :pending_to_pending | :pending_to_posted | :pending_to_archived

  # Define the core account types function and the core account type
  @account_types [:asset, :liability, :equity, :revenue, :expense]
  @type account_type :: unquote(Enum.reduce(@account_types, fn state, acc -> quote do: unquote(state) | unquote(acc) end))

  @spec account_types() :: [account_type]
  def account_types, do: @account_types
end
