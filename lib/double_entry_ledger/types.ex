defmodule DoubleEntryLedger.Types do
  @moduledoc """
  Defines the type specifications and constants for the DoubleEntryLedger system.

  This module contains type definitions that represent core accounting concepts used
  throughout the application. It provides both the type specifications for static
  type checking and helper functions to access the allowed values at runtime.

  ## Credit and Debit Types

  * `credit_or_debit` - Represents the two fundamental transaction entry types in accounting
  * `credit_and_debit` - A list containing both credit and debit values

  ## Account Types

  * `account_type` - The five standard accounting categories:
    * `:asset` - Resources owned by the entity (cash, receivables, inventory)
    * `:liability` - Obligations owed by the entity (payables, loans)
    * `:equity` - Residual interest in assets after deducting liabilities
    * `:revenue` - Income earned from normal business operations
    * `:expense` - Costs incurred in normal business operations

  ## Transaction Types

  * `trx_types` - Different states and transitions for transactions:
    * `:posted` - Final recorded transaction
    * `:pending` - Transaction awaiting confirmation
    * `:pending_to_pending` - A pending transaction still pending after modification
    * `:pending_to_posted` - A pending transaction becoming posted
    * `:pending_to_archived` - A pending transaction becoming archived

  ## Usage Examples

  Getting all account types:

      DoubleEntryLedger.Types.account_types()
      # Returns [:asset, :liability, :equity, :revenue, :expense]

  Getting credit and debit types:

      DoubleEntryLedger.Types.credit_and_debit()
      # Returns [:credit, :debit]

  Using the types in function specifications:

      @spec process_entry(account_id :: Ecto.UUID.t(), amount :: integer, type :: DoubleEntryLedger.Types.credit_or_debit()) :: Entry.t()
  """

  # Define the credit and debit types
  @credit_and_debit [:credit, :debit]

  @typedoc """
  Represents a credit or debit entry type in double-entry accounting.
  """
  @type credit_or_debit ::
          unquote(
            Enum.reduce(@credit_and_debit, fn state, acc ->
              quote do: unquote(state) | unquote(acc)
            end)
          )

  @typedoc """
  A list containing both credit and debit types.
  """
  @type credit_and_debit :: [credit_or_debit]

  @doc """
  Returns a list of credit and debit types used in accounting entries.

  These represent the two fundamental operation types in double-entry accounting,
  where every financial transaction must have equal amounts of credits and debits.

  ## Returns

  * `[:credit, :debit]` - A list of atoms representing the entry types

  ## Usage Example

      DoubleEntryLedger.Types.credit_and_debit()
      # => [:credit, :debit]
  """
  @spec credit_and_debit() :: credit_and_debit()
  def credit_and_debit, do: @credit_and_debit

  @typedoc """
  Transaction states and transitions in the ledger system.
  """
  @type trx_types ::
          :posted | :pending | :pending_to_pending | :pending_to_posted | :pending_to_archived

  # Define the core account types function and the core account type
  @account_types [:asset, :liability, :equity, :revenue, :expense]

  @typedoc """
  The five standard accounting categories for classifying accounts.
  """
  @type account_type ::
          unquote(
            Enum.reduce(@account_types, fn state, acc ->
              quote do: unquote(state) | unquote(acc)
            end)
          )

  @doc """
  Returns a list of standard account types used in accounting.

  These represent the five fundamental categories in accounting that classify
  all financial accounts within a ledger system.

  ## Returns

  * `[:asset, :liability, :equity, :revenue, :expense]` - A list of atoms representing account types

  ## Account Type Descriptions

  * `:asset` - Resources owned by the entity (cash, receivables, inventory)
  * `:liability` - Obligations owed by the entity (payables, loans)
  * `:equity` - Residual interest in assets after deducting liabilities
  * `:revenue` - Income earned from normal business operations
  * `:expense` - Costs incurred in normal business operations

  ## Usage Example

      DoubleEntryLedger.Types.account_types()
      # => [:asset, :liability, :equity, :revenue, :expense]
  """
  @spec account_types() :: [account_type]
  def account_types, do: @account_types
end
