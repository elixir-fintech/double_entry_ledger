defmodule DoubleEntryLedger.Workers.Oban.CreateTransactionLink do
  @moduledoc """
  Oban worker to create AccountLink
  """
  use Oban.Worker, queue: :double_entry_ledger

  alias DoubleEntryLedger.{EventTransactionLink, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"event_id" => eid, "transaction_id" => tid, "journal_event_id" => jid}
      }) do
    Repo.insert(changeset(eid, tid, jid))
  end

  defp changeset(event_id, transaction_id, journal_event_id) do
    %EventTransactionLink{}
    |> EventTransactionLink.changeset(%{
      event_id: event_id,
      transaction_id: transaction_id,
      journal_event_id: journal_event_id
    })
  end
end
