defmodule DoubleEntryLedger.Workers.Oban.CreateAccountLink do
  @moduledoc """
  Oban worker to create AccountLink
  """
  use Oban.Worker, queue: :double_entry_ledger

  alias DoubleEntryLedger.{JournalEventAccountLink, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"command_id" => eid, "account_id" => aid, "journal_event_id" => jid}
      }) do
    Repo.insert(changeset(eid, aid, jid))
  end

  defp changeset(command_id, account_id, journal_event_id) do
    %JournalEventAccountLink{}
    |> JournalEventAccountLink.changeset(%{
      command_id: command_id,
      account_id: account_id,
      journal_event_id: journal_event_id
    })
  end
end
