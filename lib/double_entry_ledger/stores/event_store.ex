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

  @spec mark_as_processed(Event.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def mark_as_processed(event, transaction_id) do
    event
    |> Ecto.Changeset.change(status: :processed, processed_at: DateTime.utc_now(), processed_transaction_id: transaction_id)
  end

  @spec mark_as_failed(Event.t(), String.t()) :: Ecto.Changeset.t()
  def mark_as_failed(event, reason) do
    event
    |> Ecto.Changeset.change(status: :failed, errors: [build_error(reason) | event.errors])
  end

  @spec add_error(Event.t(), any()) :: Ecto.Changeset.t()
  def add_error(event, error) do
    event
    |> Ecto.Changeset.change(errors: [build_error(error) | event.errors])
  end

  defp build_error(error) do
    %{
      message: error,
      inserted_at: DateTime.utc_now(:microsecond),
    }
  end
end
