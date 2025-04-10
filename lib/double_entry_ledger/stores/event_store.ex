defmodule DoubleEntryLedger.EventStore do
  @moduledoc """
  This module defines the EventStore behaviour.
  """
  import Ecto.Query
  import DoubleEntryLedger.EventStoreHelper
  import DoubleEntryLedger.OccRetry, only: [retry_interval: 0]

  alias Ecto.Changeset
  alias DoubleEntryLedger.{Repo, Event, Transaction}
  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.EventWorker

  @retry_interval retry_interval()

  @spec get_by_id(Ecto.UUID.t()) :: Event.t() | nil
  def get_by_id(id) do
    Repo.get(Event, id)
  end

  @spec claim_event_for_processing(Ecto.UUID.t(), String.t(), Ecto.Repo.t()) ::
          {:ok, Event.t()} | {:error, atom()}
  def claim_event_for_processing(id, processor_id \\ "manual", repo \\ Repo) do
    case get_by_id(id) do
      nil ->
        {:error, :event_not_found}

      event ->
        if event.status in [:pending, :occ_timeout] do
          try do
            Event.processing_start_changeset(event, processor_id)
            |> repo.update()
          rescue
            Ecto.StaleEntryError ->
              {:error, :event_not_claimable}
          end
        else
          {:error, :event_not_claimable}
        end
    end
  end

  @spec create(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    build_create(attrs)
    |> Repo.insert()
  end

  @spec process_from_event_params(map()) ::
          {:ok, Transaction.t(), Event.t()}
          | {:error, Event.t() | Ecto.Changeset.t() | String.t()}
  def process_from_event_params(event_params) do
    case EventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end

  @spec list_all_for_instance(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          list(Event.t())
  def list_all_for_instance(instance_id, page \\ 1, per_page \\ 40) do
    offset = (page - 1) * per_page

    Repo.all(
      from(e in Event,
        where: e.instance_id == ^instance_id,
        order_by: [desc: e.inserted_at],
        limit: ^per_page,
        offset: ^offset,
        select: e
      )
    )
  end

  @spec list_all_for_transaction(Ecto.UUID.t()) :: list(Event.t())
  def list_all_for_transaction(transaction_id) do
    Repo.all(
      from(e in Event,
        where: e.processed_transaction_id == ^transaction_id,
        select: e,
        order_by: [desc: e.inserted_at]
      )
    )
  end

  @spec create_event_after_failure(Event.t(), list(), integer(), atom()) ::
          {:ok, Event.t()} | {:error, Changeset.t()}
  def create_event_after_failure(event, errors, retries, status) do
    event
    |> Changeset.change(errors: errors, status: status, occ_retry_count: retries)
    |> Repo.insert()
  end

  @spec mark_as_processed(Event.t(), Ecto.UUID.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_processed(event, transaction_id) do
    event
    |> build_mark_as_processed(transaction_id)
    |> Repo.update()
  end

  @spec mark_as_occ_timeout(Event.t(), String.t(), non_neg_integer()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_occ_timeout(event, reason, time_interval \\ @retry_interval) do
    now = DateTime.utc_now()
    next_retry_after = DateTime.add(now, time_interval, :millisecond)
    event
    |> build_add_error(reason)
    |> Changeset.change(
      status: :occ_timeout,
      processing_completed_at: now,
      next_retry_after: next_retry_after
      )
    |> Repo.update()
  end

  @spec mark_as_failed(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def mark_as_failed(event, reason) do
    event
    |> build_add_error(reason)
    |> Changeset.change(status: :failed)
    |> Repo.update()
  end

  @spec add_error(Event.t(), any()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def add_error(event, error) do
    event
    |> build_add_error(error)
    |> Repo.update()
  end
end
