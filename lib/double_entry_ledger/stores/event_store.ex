defmodule DoubleEntryLedger.EventStore do
  @moduledoc """
  This module defines the EventStore behaviour.
  """

  alias DoubleEntryLedger.{Repo, Event}

  def insert_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  def mark_as_processed(event) do
    event
    |> Ecto.Changeset.change(status: :processed, processed_at: DateTime.utc_now())
    |> Repo.update()
  end

  def mark_as_failed(event, _reason) do
    # TODO log reason in event
    event
    |> Ecto.Changeset.change(status: :failed)
    |> Repo.update()
  end
end
