defmodule DoubleEntryLedger.EventWorker.EventTransformer do
  @moduledoc """
  Provides helper functions for processing events within the double-entry ledger system.

  This module includes functions to transform transaction and entry data into the formats
  required by the ledger, handling account retrieval, and mapping entries.
  """

  alias DoubleEntryLedger.{Account, AccountStore}
  alias DoubleEntryLedger.Event.{EntryData, TransactionData}

  import DoubleEntryLedger.Currency

  @doc """
  Transforms transaction data into a transaction map suitable for ledger operations.

  ## Parameters

    - `transaction_data` - A `%TransactionData{}` struct containing the transaction information.
    - `instance_id` - The UUID of the instance associated with the transaction.

  ## Returns

    - `{:ok, transaction_map}` on success.
    - `{:error, reason}` if an error occurs during transformation.
  """
  @spec transaction_data_to_transaction_map(TransactionData.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, String.t()}
  def transaction_data_to_transaction_map(%{entries: [], status: status}, instance_id) do
    {:ok, %{instance_id: instance_id, status: status}}
  end

  def transaction_data_to_transaction_map(%{entries: entries, status: status}, instance_id) do
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
  end

  @spec get_accounts_with_entries(Ecto.UUID.t(), list(EntryData.t())) ::
          {:ok, list({Account.t(), EntryData.t()})} | {:error, String.t()}
  defp get_accounts_with_entries(instance_id, entries) do
    account_ids = Enum.map(entries, & &1.account_id)

    case AccountStore.get_accounts_by_instance_id(instance_id, account_ids) do
      {:ok, accounts} -> {:ok, struct_match_accounts_entries(accounts, entries)}
      {:error, error} -> {:error, error}
    end
  end

  @spec struct_match_accounts_entries(list(Account.t()), list(EntryData.t())) ::
          list({Account.t(), EntryData.t()})
  defp struct_match_accounts_entries(accounts, entries) do
    entries_map =
      Map.new(
        entries,
        fn %{account_id: id} = entry_data -> {id, entry_data} end
      )

    Enum.flat_map(accounts, fn %Account{id: id} = account ->
      case Map.fetch(entries_map, id) do
        {:ok, entry_data} -> [{account, entry_data}]
        :error -> []
      end
    end)
  end

  @spec entry_data_to_entry_map({Account.t(), EntryData.t()}) :: map()
  defp entry_data_to_entry_map({%{normal_balance: :debit} = acc, %{amount: amt} = ed}) when amt > 0 do
    %{account_id: acc.id, value: to_abs_money(amt, ed.currency), type: :debit}
  end

  defp entry_data_to_entry_map({%{normal_balance: :debit} = acc, ed}) do
    %{account_id: acc.id, value: to_abs_money(ed.amount, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{normal_balance: :credit} = acc, %{amount: amt} = ed}) when amt > 0 do
    %{account_id: acc.id, value: to_abs_money(amt, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{normal_balance: :credit} = acc, ed}) do
    %{account_id: acc.id, value: to_abs_money(ed.amount, ed.currency), type: :debit}
  end
end
