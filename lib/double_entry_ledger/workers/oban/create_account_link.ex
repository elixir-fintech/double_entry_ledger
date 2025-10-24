defmodule DoubleEntryLedger.Workers.Oban.CreateAccountLink do
  @moduledoc """
  Oban worker to create AccountLink
  """
  use Oban.Worker, queue: :double_entry_ledger

  alias DoubleEntryLedger.{EventAccountLink, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"event_id" => eid, "account_id" => aid, "journal_event_id" => jid}
      }) do
    Repo.insert(changeset(eid, aid, jid))
  end

  defp changeset(event_id, account_id, journal_event_id) do
    %EventAccountLink{}
    |> EventAccountLink.changeset(%{
      event_id: event_id,
      account_id: account_id,
      journal_event_id: journal_event_id
    })
  end
end
