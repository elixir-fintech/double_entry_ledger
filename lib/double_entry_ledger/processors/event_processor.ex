defmodule DoubleEntryLedger.EventProcessor do
  @moduledoc """
  This module processes events and updates the balances of the accounts
  """

  alias DoubleEntryLedger.EventStore
  alias DoubleEntryLedger.{
    Account, AccountStore,
    Event, Transaction, TransactionStore
  }
  alias DoubleEntryLedger.Event.TransactionData
  alias DoubleEntryLedger.Event.EntryData


  @spec process_event(Event.t()) :: {:ok, Transaction.t()} | {:error, String.t()}
  def process_event(%Event{status: status, action: action } = event) when status == :pending do
    case action do
      :create -> create_transaction(event)
      :update -> update_transaction(event)
      _ -> {:error, "Action is not supported"}
    end
  end

  def process_event(_event) do
    {:error, "Event is not in pending state"}
  end

  @spec create_transaction(Event.t()) :: {:ok, Transaction.t() } | {:error, String.t()}
  defp create_transaction(%Event{transaction_data: td} = event) do
    case convert_payload_to_transaction_map(td) do
      {:ok, transaction_map} ->
        case TransactionStore.create(transaction_map) do
          {:ok, transaction} ->
            EventStore.mark_as_processed(event)
            {:ok, transaction}
          {:error, error} ->
            EventStore.mark_as_failed(event, error)
            {:error, error}
        end
      {:error, error} ->
        EventStore.mark_as_failed(event, error)
        {:error, error}
    end
  end

  defp update_transaction(_event) do
    {:error, "Update action is not supported"}
  end

  @spec convert_payload_to_transaction_map(TransactionData.t()) :: {:ok, map() } | {:error, String.t()}
  defp convert_payload_to_transaction_map(%TransactionData{instance_id: id, entries: entries, status: status}) do
    case get_accounts_with_entries(id, entries) do
      {:ok, accounts_and_entries} -> {:ok, %{
          instance_id: id,
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
  defp entry_data_to_entry_map({%{type: type} = acc, %{amount: amt} = ed}) when type == :debit and amt > 0 do
    %{account_id: acc.id, amount: to_money(amt, ed.currency), type: :debit}
  end

  defp entry_data_to_entry_map({%{type: type} = acc, ed}) when type == :debit do
    %{account_id: acc.id, amount: to_money(ed.amount, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{type: type} = acc, %{amount: amt} = ed}) when type == :credit and amt > 0 do
    %{account_id: acc.id, amount: to_money(amt, ed.currency), type: :credit}
  end

  defp entry_data_to_entry_map({%{type: type} = acc, ed}) when type == :credit do
    %{account_id: acc.id, amount: to_money(ed.amount, ed.currency), type: :debit}
  end

  defp to_money(amount, currency) do
    Money.new(abs(amount), currency)
  end
end
