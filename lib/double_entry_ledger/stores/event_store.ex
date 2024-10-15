defmodule DoubleEntryLedger.EventStore do
  @moduledoc """
  This module defines the EventStore behaviour.
  """

  alias DoubleEntryLedger.{Repo, Event}

  @spec insert_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def insert_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @spec mark_as_processed(Event.t(), Ecto.UUID.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_processed(event, transaction_id) do
    event
    |> Ecto.Changeset.change(status: :processed, processed_at: DateTime.utc_now(), processed_transaction_id: transaction_id)
    |> Repo.update()
  end

  @spec mark_as_failed(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_failed(event, _reason) do
    # TODO log reason in event
    event
    |> Ecto.Changeset.change(status: :failed)
    |> Repo.update()
  end
end
