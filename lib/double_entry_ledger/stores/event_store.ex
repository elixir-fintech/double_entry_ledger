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

  def get_event(id) do
    case Repo.get(Event, id) do
      nil -> {:error, "Event not found"}
      event -> {:ok, event}
    end
  end

  @spec get_create_event_by_source(String.t(), String.t(), Ecto.UUID.t()) :: Event.t() | nil
  def get_create_event_by_source(source, source_idempk, instance_id) do
    Event
    |> Repo.get_by(action: :create, source: source, source_idempk: source_idempk, instance_id: instance_id)
    |> Repo.preload(processed_transaction: [entries: :account])
  end

  @spec mark_as_processed(Event.t(), Ecto.UUID.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_processed(event, transaction_id) do
    event
    |> build_mark_as_processed(transaction_id)
    |> Repo.update()
  end

  @spec build_mark_as_processed(Event.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def build_mark_as_processed(event, transaction_id) do
    event
    |> Ecto.Changeset.change(status: :processed, processed_at: DateTime.utc_now(), processed_transaction_id: transaction_id)
  end

  @spec mark_as_failed(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def mark_as_failed(event, reason) do
    event
    |> build_add_error(reason)
    |> Ecto.Changeset.change(status: :failed)
    |> Repo.update()
  end

  @spec build_add_error(Event.t(), any()) :: Ecto.Changeset.t()
  def build_add_error(event, error) do
    event
    |> Ecto.Changeset.change(errors: [build_error(error) | event.errors])
  end

  @spec add_error(Event.t(), any()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def add_error(event, error) do
    event
    |> build_add_error(error)
    |> Repo.update()
  end

  defp build_error(error) do
    %{
      message: error,
      inserted_at: DateTime.utc_now(:microsecond),
    }
  end
end
