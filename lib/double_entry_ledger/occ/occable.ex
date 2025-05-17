alias DoubleEntryLedger.Event
alias DoubleEntryLedger.Event.ErrorMap
alias DoubleEntryLedger.Event.EventMap
alias DoubleEntryLedger.Occ.Helper
alias Ecto.Multi

defprotocol DoubleEntryLedger.Occ.Occable do
  @moduledoc """
  Protocol for handling Optimistic Concurrency Control (OCC) in the double-entry ledger system.

  This protocol defines the behavior required for entities that use optimistic concurrency
  control for database operations. It provides methods for:

  1. Updating entities during retry attempts when conflicts occur
  2. Handling timeout situations when maximum retries are reached

  Implementing this protocol allows an entity to participate in the OCC process
  with standardized error handling and retry mechanisms.
  """

  @doc """
  Updates the entity with retry information during OCC retry cycles.

  When an optimistic concurrency conflict is detected, this function is called
  to record the retry attempt and associated error information.

  ## Parameters
    - `impl_struct` - The struct implementing this protocol
    - `error_map` - Map containing retry count and error details
    - `repo` - Ecto.Repo to use for the update operation

  ## Returns
    - The updated struct with retry information
  """
  @spec update!(t(), ErrorMap.t(), Ecto.Repo.t()) :: t()
  def update!(impl_struct, error_map, repo)

  @doc """
  Handles the timeout scenario when maximum OCC retries are reached.

  When the system has attempted the configured maximum number of retries
  and still encounters conflicts, this function is called to finalize
  the entity state and return an appropriate error tuple.

  ## Parameters
    - `impl_struct` - The struct implementing this protocol
    - `error_map` - Map containing retry count and accumulated errors
    - `repo` - Ecto.Repo to use for the update operation

  ## Returns
    - A tuple containing error details and the final state of the entity
  """
  @spec timed_out(t(), atom(), ErrorMap.t()) ::
          Multi.t()
  def timed_out(impl_struct, name, error_map)
end

defimpl DoubleEntryLedger.Occ.Occable, for: Event do
  alias Ecto.Multi

  @doc """
  Updates an Event with retry information during OCC retry cycles.

  Records the retry count and error information in the Event record.

  ## Parameters
    - `event` - The Event struct to update
    - `error_map` - Contains retry count and error details
    - `repo` - Ecto.Repo to use for the update

  ## Returns
    - The updated Event struct
  """
  @spec update!(Event.t(), ErrorMap.t(), Ecto.Repo.t()) :: Event.t()
  def update!(event, error_map, repo) do
    event
    |> Ecto.Changeset.change(occ_retry_count: error_map.retries, errors: error_map.errors)
    |> repo.update!()
  end

  @doc """
  Handles OCC timeout for an Event when maximum retries are reached.

  Updates the Event to reflect the OCC timeout status and returns
  an error tuple with the appropriate error code.

  ## Parameters
    - `event` - The Event that has reached maximum retries
    - `error_map` - Contains retry count and accumulated errors
    - `repo` - Ecto.Repo to use for the update

  ## Returns
    - Error tuple containing the updated Event and timeout indication
  """
  @spec timed_out(Event.t(), atom(), ErrorMap.t()) ::
          Multi.t()
  def timed_out(event, name, error_map) do
    Multi.new()
    |> Multi.update(name, fn _ ->
      event
      |> Helper.occ_timeout_changeset(error_map)
    end)
  end
end

defimpl DoubleEntryLedger.Occ.Occable, for: EventMap do
  @doc """
  Updates an EventMap during OCC retry cycles.

  For EventMap, this is a no-op since EventMaps are transient and
  not stored in the database.

  ## Parameters
    - `event_map` - The EventMap struct
    - `_error_map` - Contains retry count and errors (unused)
    - `_repo` - Ecto.Repo to use (unused)

  ## Returns
    - The unchanged EventMap struct
  """
  @spec update!(EventMap.t(), ErrorMap.t(), Ecto.Repo.t()) :: EventMap.t()
  def update!(event_map, _error_map, _repo), do: event_map

  @doc """
  Handles OCC timeout for an EventMap when maximum retries are reached.

  Creates and stores a permanent Event record from the EventMap data
  with timeout status, then returns an error tuple.

  ## Parameters
    - `_event_map` - The EventMap that has reached maximum retries
    - `error_map` - Contains retry count, errors, and created Event
    - `repo` - Ecto.Repo to use for storing the Event

  ## Returns
    - Error tuple containing the created Event and timeout indication
  """
  @spec timed_out(EventMap.t(), atom(), ErrorMap.t()) ::
          Multi.t()
  def timed_out(_event_map, name, error_map) do
    Multi.new()
    |> Multi.insert(name, fn _ ->
      error_map.steps_so_far.create_event
      |> Helper.occ_timeout_changeset(error_map)
    end)
  end
end
