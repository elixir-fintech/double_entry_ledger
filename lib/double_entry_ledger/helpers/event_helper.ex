defmodule DoubleEntryLedger.EventHelper do
  @moduledoc """
  Helper functions for events.
  """

  alias DoubleEntryLedger.{Account, AccountStore}
  alias DoubleEntryLedger.Event.{EntryData, TransactionData}

  import DoubleEntryLedger.Currency

  @spec transaction_data_to_transaction_map(TransactionData.t(), Ecto.UUID.t()) :: {:ok, map() } | {:error, String.t()}
  def transaction_data_to_transaction_map(%{entries: [], status: status}, instance_id) do
    {:ok, %{instance_id: instance_id, status: status}}
  end

  def transaction_data_to_transaction_map(%{entries: entries, status: status}, instance_id) do
    case get_accounts_with_entries(instance_id, entries) do
      {:ok, accounts_and_entries} -> {:ok, %{
          instance_id: instance_id,
          status: status,
          entries: Enum.map(accounts_and_entries, &entry_data_to_entry_map/1)
        }}
      {:error, error} -> {:error, error}
    end
  end

  @spec get_accounts_with_entries(Ecto.UUID.t(), list(EntryData.t())) :: {:ok, list({Account.t(), EntryData.t()})} | {:error, String.t()}
  defp get_accounts_with_entries(instance_id, entries) do
    account_ids = Enum.map(entries, &(&1.account_id))
    case AccountStore.get_accounts_by_instance_id(instance_id, account_ids) do
      {:ok, accounts} -> {:ok, struct_match_accounts_entries(accounts, entries)}
      {:error, error} -> {:error, error}
    end
  end

  @spec struct_match_accounts_entries(list(Account.t()), list(EntryData.t())) :: list({Account.t(), EntryData.t()})
  defp struct_match_accounts_entries(accounts, entries) do
    entries_map = Map.new(
      entries,
      fn %EntryData{account_id: id} = entry_data -> {id, entry_data} end
    )

    Enum.flat_map(accounts, fn %Account{id: id} = account ->
      case Map.fetch(entries_map, id) do
        {:ok, entry_data} -> [{account, entry_data}]
        :error -> []
      end
    end)
  end

  @spec entry_data_to_entry_map({Account.t(), EntryData.t()}) :: map()
  defp entry_data_to_entry_map({%{type: :debit} = acc, %{amount: amt} = ed}) when amt > 0 do
    %{account_id: acc.id, value: to_abs_money(amt, ed.currency), type: :debit}
  end

  defp entry_data_to_entry_map({%{type: :debit} = acc, ed}) do
    %{account_id: acc.id, value: to_abs_money(ed.amount, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{type: :credit} = acc, %{amount: amt} = ed}) when amt > 0 do
    %{account_id: acc.id, value: to_abs_money(amt, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{type: :credit} = acc, ed}) do
    %{account_id: acc.id, value: to_abs_money(ed.amount, ed.currency), type: :debit}
  end
end
