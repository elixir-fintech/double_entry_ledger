defmodule DoubleEntryLedger.EventStoreHelper do
  @moduledoc """
  This module provides helper functions for working with events in the Double Entry Ledger system.
  """
  alias Ecto.Changeset
  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.{Repo, Event, Transaction}
  alias DoubleEntryLedger.EventWorker.AddUpdateEventError

  @spec build_create(map()) :: Changeset.t()
  def build_create(attrs) do
    %Event{}
    |> Event.changeset(attrs)
  end

  @spec get_create_event_by_source(String.t(), String.t(), Ecto.UUID.t()) :: Event.t() | nil
  def get_create_event_by_source(source, source_idempk, instance_id) do
    Event
    |> Repo.get_by(
      action: :create,
      source: source,
      source_idempk: source_idempk,
      instance_id: instance_id
    )
    |> Repo.preload(processed_transaction: [entries: :account])
  end

  @spec get_create_event_transaction(Event.t()) ::
          {:ok, {Transaction.t(), Event.t()}}
          | {:error | :pending_error, String.t(), Event.t() | nil}
  def get_create_event_transaction(
        %{
          source: source,
          source_idempk: source_idempk,
          instance_id: id
        } = event
      ) do
    case get_create_event_by_source(source, source_idempk, id) do
      %{processed_transaction: %{id: _} = transaction, status: :processed} = create_event ->
        {:ok, {transaction, create_event}}

      create_event ->
        raise AddUpdateEventError, create_event: create_event, update_event: event
    end
  end

  @spec build_get_create_event_transaction(Ecto.Multi.t(), atom(), Event.t() | atom()) ::
          Ecto.Multi.t()
  def build_get_create_event_transaction(multi, step, event_or_step) do
    multi
    |> Multi.run(step, fn _, changes ->
      event =
        cond do
          is_struct(event_or_step, Event) -> event_or_step
          is_atom(event_or_step) -> Map.fetch!(changes, event_or_step)
        end

      try do
        {:ok, {transaction, _}} = get_create_event_transaction(event)
        {:ok, transaction}
      rescue
        e in AddUpdateEventError ->
          {:error, e}
      end
    end)
  end

  @spec build_mark_as_processed(Event.t(), Ecto.UUID.t()) :: Changeset.t()
  def build_mark_as_processed(event, transaction_id) do
    event
    |> Changeset.change(
      status: :processed,
      processed_at: DateTime.utc_now(),
      processed_transaction_id: transaction_id
    )
    |> increment_tries()
  end

  @spec build_add_error(Event.t(), any()) :: Changeset.t()
  def build_add_error(event, error) do
    event
    |> Changeset.change(errors: [build_error(error) | event.errors])
    |> increment_tries()
  end

  @spec build_error(String.t()) :: %{message: String.t(), inserted_at: DateTime.t()}
  defp build_error(error) do
    %{
      message: error,
      inserted_at: DateTime.utc_now(:microsecond)
    }
  end

  @spec increment_tries(Changeset.t()) :: Changeset.t()
  defp increment_tries(changeset) do
    current_tries = Changeset.get_field(changeset, :tries) || 0
    Changeset.put_change(changeset, :tries, current_tries + 1)
  end
end
