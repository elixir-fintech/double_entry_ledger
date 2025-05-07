defmodule DoubleEntryLedger.EventStoreHelper do
  @moduledoc """
  Helper functions for event processing in the Double Entry Ledger system.

  This module provides reusable utilities for working with events, focusing on common
  operations like building changesets, retrieving related events and transactions, and
  creating multi operations for use in Ecto transactions.

  ## Key Functionality

  * **Changeset Building**: Create Event changesets from EventMaps or attribute maps
  * **Event Relationships**: Look up related events by source identifiers
  * **Transaction Linking**: Find transactions associated with events
  * **Ecto.Multi Integration**: Build multi operations for atomic database transactions
  * **Status Management**: Create changesets to update event status and error information

  ## Usage Examples

  Building a changeset from an EventMap:

      event_changeset = EventStoreHelper.build_create(event_map)

  Adding a step to get a create event's transaction:

      multi =
        Ecto.Multi.new()
        |> EventStoreHelper.build_get_create_event_transaction(:transaction, update_event)
        |> Ecto.Multi.update(:event, fn %{transaction: transaction} ->
          EventStoreHelper.build_mark_as_processed(update_event, transaction.id)
        end)

  ## Implementation Notes

  This module is primarily used internally by EventStore and EventWorker modules to
  share common functionality and reduce code duplication.
  """
  import DoubleEntryLedger.Event.ErrorMap, only: [build_error: 1]
  alias DoubleEntryLedger.Event.EventMap
  alias Ecto.Changeset
  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.Event.EventMap
  alias DoubleEntryLedger.{Repo, Event, Transaction}
  alias DoubleEntryLedger.EventWorker.AddUpdateEventError

  @doc """
  Builds an Event changeset from an EventMap or attribute map.

  ## Parameters
    - `event_map_or_attrs`: Either an EventMap struct or a plain map of attributes

  ## Returns
    - `Ecto.Changeset.t()`: A changeset for creating a new Event
  """
  @spec build_create(EventMap.t() | map()) :: Changeset.t()
  def build_create(%EventMap{} = event_map) do
    %Event{}
    |> Event.changeset(EventMap.to_map(event_map))
  end

  def build_create(attrs) do
    %Event{}
    |> Event.changeset(attrs)
  end

  @doc """
  Gets an event by its source identifiers.

  This function looks up a create event using its source, source_idempk, and instance_id,
  preloading the associated transaction and its entries.

  ## Parameters
    - `source`: The source system identifier (e.g., "accounting_system")
    - `source_idempk`: The source-specific identifier (e.g., "invoice_123")
    - `instance_id`: The instance UUID

  ## Returns
    - `Event.t() | nil`: The found event with preloaded transaction and entries, or nil if not found
  """
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

  @doc """
  Gets the transaction associated with a create event.

  This function finds the original create event corresponding to an update event
  and returns its associated transaction.

  ## Parameters
    - `event`: An Event struct containing source, source_idempk, and instance_id

  ## Returns
    - `{:ok, {Transaction.t(), Event.t()}}`: The transaction and create event if found and processed
    - Raises `AddUpdateEventError` if the create event doesn't exist or isn't processed

  ## Implementation Notes
  This is typically used when processing update events to find the original transaction to modify.
  """
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

  @doc """
  Builds an Ecto.Multi step to get a create event's transaction.

  This function adds a step to an Ecto.Multi that retrieves the transaction associated with
  the create event corresponding to an update event.

  ## Parameters
    - `multi`: The Ecto.Multi instance
    - `step`: The atom representing the step name
    - `event_or_step`: Either an Event struct or the name of a previous step in the Multi

  ## Returns
    - `Ecto.Multi.t()`: The updated Multi instance with the new step added
  """
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

  @doc """
  Builds a changeset to add an error to an event.

  This function appends a new error to the event's error list.

  ## Parameters
    - `event`: The Event struct to update
    - `error`: The error to add

  ## Returns
    - `Ecto.Changeset.t()`: The changeset for adding the error
  """
  @spec build_add_error(Event.t(), any()) :: Changeset.t()
  def build_add_error(event, error) do
    event
    |> Changeset.change(errors: [build_error(error) | event.errors])
  end
end
