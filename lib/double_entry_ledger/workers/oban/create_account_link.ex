defmodule DoubleEntryLedger.Workers.Oban.CreateAccountLink do
  @moduledoc """
  Oban worker to create AccountLink
  """
  use Oban.Worker, queue: :double_entry_ledger

  alias DoubleEntryLedger.{EventAccountLink, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id, "account_id" => account_id}}) do
    Repo.insert(changeset(event_id, account_id))
  end

  defp changeset(event_id, account_id) do
    %EventAccountLink{}
    |> EventAccountLink.changeset(%{
      event_id: event_id,
      account_id: account_id
    })
  end
end
