defmodule DoubleEntryLedger.EventStore do
  @moduledoc """
  This module defines the EventStore behaviour.
  """
  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.{Repo, Event, Transaction}
  alias DoubleEntryLedger.EventStore.CreateEventError

  @spec insert_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def insert_event(attrs) do
    build_insert_event(attrs)
    |> Repo.insert()
  end

  @spec build_insert_event(map()) :: Ecto.Changeset.t()
  def build_insert_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
  end

  @spec create_event_after_failure(Event.t(), list(), integer(), atom()) ::
          {:ok, Event.t()} | {:error, Changeset.t()}
  def create_event_after_failure(event, errors, retries, status) do
    event
    |> Changeset.change(errors: errors, status: status, tries: retries)
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
  def get_create_event_transaction(%{
        source: source,
        source_idempk: source_idempk,
        instance_id: id
      } = event) do
    case get_create_event_by_source(source, source_idempk, id) do
      %{processed_transaction: %{id: _} = transaction, status: :processed} = create_event ->
        {:ok, {transaction, create_event}}

      create_event ->
        raise CreateEventError, create_event: create_event, update_event: event
    end
  end

  @spec build_get_create_event_transaction(Ecto.Multi.t(), atom(), Event.t() | atom()) :: Ecto.Multi.t()
  def build_get_create_event_transaction(multi, step, event_or_step) do
    multi
    |> Multi.run(step, fn _, changes ->
      event = cond do
        is_struct(event_or_step, Event) -> event_or_step
        is_atom(event_or_step) -> Map.fetch!(changes, event_or_step)
      end

      try do
        {:ok, {transaction, _}} = get_create_event_transaction(event)
        {:ok, transaction}
      rescue
        e in CreateEventError ->
          {:error, e}
      end
    end)
  end

  @spec mark_as_processed(Event.t(), Ecto.UUID.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_processed(event, transaction_id) do
    event
    |> build_mark_as_processed(transaction_id)
    |> Repo.update()
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

  @spec mark_as_occ_timeout(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_occ_timeout(event, reason) do
    event
    |> build_add_error(reason)
    |> Changeset.change(status: :occ_timeout)
    |> Repo.update()
  end

  @spec mark_as_failed(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_failed(event, reason) do
    event
    |> build_add_error(reason)
    |> Changeset.change(status: :failed)
    |> Repo.update()
  end

  @spec build_add_error(Event.t(), any()) :: Changeset.t()
  def build_add_error(event, error) do
    event
    |> Changeset.change(errors: [build_error(error) | event.errors])
    |> increment_tries()
  end

  @spec add_error(Event.t(), any()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def add_error(event, error) do
    event
    |> build_add_error(error)
    |> Repo.update()
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


defmodule DoubleEntryLedger.EventStore.CreateEventError do
  defexception [:message, :create_event, :update_event, :reason]

  alias DoubleEntryLedger.Event
  alias __MODULE__, as: CreateEventError

  @impl true
  def exception(opts) do
    update_event = Keyword.get(opts, :update_event)
    create_event = Keyword.get(opts, :create_event)
    case create_event do
      %Event{status: :pending} ->
        %CreateEventError{
          message: "Create event (id: #{create_event.id}) has not yet been processed for Update Event (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_pending}
      %Event{status: :failed} ->
        %CreateEventError{
          message: "Create event (id: #{create_event.id}) has failed for Update Event (id: #{update_event.id})",
          create_event: create_event,
          update_event: update_event,
          reason: :create_event_failed
        }
      nil ->
        %CreateEventError{
          message: "Create Event not found for Update Event (id: #{update_event.id})",
          create_event: nil,
          update_event: update_event,
          reason: :create_event_not_found
        }
    end
  end
end
