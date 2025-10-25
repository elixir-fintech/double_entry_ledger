defmodule DoubleEntryLedger.Workers.CommandWorker.TransactionEventTransformer do
  @moduledoc """
  Transforms accounting events into ledger operations in the double-entry bookkeeping system.

  This module serves as a transformation layer between incoming transaction events and the internal
  ledger representation. It handles:

  - Converting transaction data to the format required by the ledger system
  - Validating transaction entries for required fields, valid currency, and integer amounts using changeset validation
  - Retrieving relevant accounts for each transaction entry
  - Determining the correct debit/credit classification based on account types
  - Ensuring monetary values are properly formatted

  The transformer provides a critical validation step, ensuring that all required accounts exist
  and that entries are properly structured and valid before they are recorded in the ledger.
  """

  alias DoubleEntryLedger.{Account, Types, Transaction}
  alias DoubleEntryLedger.Event.{EntryData, TransactionData}
  alias DoubleEntryLedger.Stores.AccountStore

  import DoubleEntryLedger.Utils.Currency

  @typedoc """
  Represents a single ledger entry with account, monetary value, and entry type.

  ## Fields

    * `:account_id` - UUID of the account associated with this entry
    * `:value` - Monetary amount as a `Money` struct (always positive)
    * `:type` - Either `:debit` or `:credit` indicating the entry type
  """
  @type entry_map() :: %{
          account_id: Ecto.UUID.t(),
          value: Money.t(),
          type: Types.credit_or_debit()
        }

  @typedoc """
  Represents a complete transaction with its entries ready for ledger processing.

  ## Fields

    * `:instance_id` - UUID of the instance this transaction belongs to
    * `:status` - Current state of the transaction (e.g. `:pending`, `:completed`)
    * `:entries` - List of entry maps that make up this transaction
  """
  @type transaction_map() :: %{
          instance_id: Ecto.UUID.t(),
          status: Transaction.state(),
          entries: list(entry_map())
        }

  @doc """
  Transforms transaction data into a transaction map suitable for ledger operations.

  This function takes incoming transaction data and converts it to the internal format
  used by the ledger system. It handles both empty transactions (no entries) and
  transactions with entries. For transactions with entries, it first validates all entries
  using changeset validation (ensuring required fields, valid currency, and integer amount).
  If validation passes, it retrieves the associated accounts and maps each entry to the appropriate entry format.

  ## Parameters

    * `transaction_data` - A `TransactionData` struct containing transaction information
      including entries and status
    * `instance_id` - UUID of the instance associated with the transaction

  ## Returns

    * `{:ok, transaction_map}` - Successfully transformed and validated transaction data
    * `{:error, reason}` - Failed to transform data, with reason as an atom (see below)

  ## Error Reasons

    * `:invalid_entry_data` - One or more entries failed changeset validation (missing/invalid fields, currency, or amount)
    * `:no_accounts_found` - No accounts found for the given instance and account IDs
    * `:some_accounts_not_found` - Some, but not all, accounts found for the given IDs
    * `:no_accounts_and_or_entries_provided` - No accounts or entries provided
    * `:account_entries_mismatch` - Number of accounts and entries do not match
    * `:missing_entry_for_account` - An account was found with no matching entry

  ## Examples

      iex> transaction_data = %TransactionData{entries: [], status: :pending}
      iex> TransactionEventTransformer.transaction_data_to_transaction_map(transaction_data, "instance-123")
      {:ok, %{instance_id: "instance-123", status: :pending}}
  """
  @spec transaction_data_to_transaction_map(TransactionData.t() | map(), Ecto.UUID.t()) ::
          {:ok, transaction_map()}
          | {:error,
             :no_accounts_found
             | :some_accounts_not_found
             | :no_accounts_and_or_entries_provided
             | :account_entries_mismatch
             | :missing_entry_for_account
             | :invalid_entry_data}
  def transaction_data_to_transaction_map(
        %TransactionData{entries: [], status: status},
        instance_id
      ) do
    {:ok, %{instance_id: instance_id, status: status}}
  end

  def transaction_data_to_transaction_map(
        %TransactionData{status: :archived},
        instance_id
      ) do
    {:ok, %{instance_id: instance_id, status: :archived}}
  end

  def transaction_data_to_transaction_map(
        %TransactionData{entries: nil, status: status},
        instance_id
      ) do
    {:ok, %{instance_id: instance_id, status: status}}
  end

  def transaction_data_to_transaction_map(
        %TransactionData{entries: entries, status: status},
        instance_id
      ) do
    case validate_entries(entries) do
      :ok ->
        case get_accounts_with_entries(instance_id, entries) do
          {:ok, accounts_and_entries} ->
            {:ok,
             %{
               instance_id: instance_id,
               status: status,
               entries: Enum.map(accounts_and_entries, &entry_data_to_entry_map/1)
             }}

          {:error, error} ->
            {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_accounts_with_entries(Ecto.UUID.t(), list(EntryData.t())) ::
          {:ok, list({Account.t(), EntryData.t()})}
          | {:error,
             :no_accounts_found
             | :some_accounts_not_found
             | :no_accounts_and_or_entries_provided
             | :account_entries_mismatch
             | :missing_entry_for_account}
  defp get_accounts_with_entries(instance_id, entries) do
    account_addresses = Enum.map(entries, & &1.account_address)

    case AccountStore.get_accounts_by_instance_id(instance_id, account_addresses) do
      {:ok, accounts} -> struct_match_accounts_entries(accounts, entries)
      {:error, error} -> {:error, error}
    end
  end

  @spec struct_match_accounts_entries(list(Account.t()), list(EntryData.t())) ::
          {:ok, list({Account.t(), EntryData.t()})}
          | {:error,
             :no_accounts_and_or_entries_provided
             | :account_entries_mismatch
             | :missing_entry_for_account}
  defp struct_match_accounts_entries(accounts, entries) when accounts == [] or entries == [] do
    {:error, :no_accounts_and_or_entries_provided}
  end

  defp struct_match_accounts_entries(accounts, entries)
       when length(accounts) != length(entries) do
    {:error, :account_entries_mismatch}
  end

  defp struct_match_accounts_entries(accounts, entries) do
    entries_map = Map.new(entries, &{&1.account_address, &1})

    pairs =
      Enum.map(accounts, fn %Account{address: address} = account ->
        case Map.get(entries_map, address) do
          nil -> throw({:error, :missing_entry_for_account})
          entry_data -> {account, entry_data}
        end
      end)

    {:ok, pairs}
  catch
    {:error, reason} -> {:error, reason}
  end

  @spec entry_data_to_entry_map({Account.t(), EntryData.t()}) :: entry_map()
  defp entry_data_to_entry_map({%{normal_balance: :debit} = acc, %{amount: amt} = ed})
       when amt > 0 do
    %{account_id: acc.id, value: to_abs_money(amt, ed.currency), type: :debit}
  end

  defp entry_data_to_entry_map({%{normal_balance: :debit} = acc, ed}) do
    %{account_id: acc.id, value: to_abs_money(ed.amount, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{normal_balance: :credit} = acc, %{amount: amt} = ed})
       when amt > 0 do
    %{account_id: acc.id, value: to_abs_money(amt, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{normal_balance: :credit} = acc, ed}) do
    %{account_id: acc.id, value: to_abs_money(ed.amount, ed.currency), type: :debit}
  end

  # Validate that all entries are valid EntryData structs with valid currency and integer amount
  # Returns :ok if all valid, or {:error, reason} if any invalid
  # Uses EntryData.changeset for validation

  @spec validate_entries(list(EntryData.t() | map())) ::
          :ok | {:error, :invalid_entry_data}
  defp validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn entry, _acc ->
      # Accept both struct and map input
      attrs = if is_struct(entry), do: Map.from_struct(entry), else: entry
      changeset = EntryData.changeset(%EntryData{}, attrs)

      if changeset.valid? do
        {:cont, :ok}
      else
        {:halt, {:error, :invalid_entry_data}}
      end
    end)
  end
end
