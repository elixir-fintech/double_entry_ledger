defmodule DoubleEntryLedger.Workers.Oban.JournalEventLinks do
  @moduledoc """
  Oban worker to create all JournalEventLinks
  """
  use Oban.Worker, queue: :double_entry_ledger

  alias Ecto.Multi

  alias DoubleEntryLedger.{
    JournalEventTransactionLink,
    JournalEventAccountLink,
    JournalEventCommandLink,
    Repo
  }

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"command_id" => cid, "transaction_id" => tid, "journal_event_id" => jid}
      }) do
    Multi.new()
    |> Multi.insert(:transaction_link, transaction_changeset(tid, jid))
    |> Multi.insert(:command_link, command_changeset(cid, jid))
    |> Repo.transaction()
  end

  def perform(%Oban.Job{
        args: %{"command_id" => cid, "account_id" => aid, "journal_event_id" => jid}
      }) do
    Multi.new()
    |> Multi.insert(:account_link, account_changeset(aid, jid))
    |> Multi.insert(:command_link, command_changeset(cid, jid))
    |> Repo.transaction()
  end

  defp account_changeset(account_id, journal_event_id) do
    %JournalEventAccountLink{}
    |> JournalEventAccountLink.changeset(%{
      account_id: account_id,
      journal_event_id: journal_event_id
    })
  end

  defp transaction_changeset(transaction_id, journal_event_id) do
    %JournalEventTransactionLink{}
    |> JournalEventTransactionLink.changeset(%{
      transaction_id: transaction_id,
      journal_event_id: journal_event_id
    })
  end

  defp command_changeset(command_id, journal_event_id) do
    %JournalEventCommandLink{}
    |> JournalEventCommandLink.changeset(%{
      command_id: command_id,
      journal_event_id: journal_event_id
    })
  end
end
