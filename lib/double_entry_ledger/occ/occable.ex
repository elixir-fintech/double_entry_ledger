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
  @spec update!(t(), DoubleEntryLedger.Event.ErrorMap.t(), Ecto.Repo.t()) :: t()
  def update!(impl_struct, error_map, repo)

  @spec build_multi(t()) :: Ecto.Multi.t()
  def build_multi(impl_struct)

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
  @spec timed_out(t(), atom(), DoubleEntryLedger.Event.ErrorMap.t()) ::
          Ecto.Multi.t()
  def timed_out(impl_struct, name, error_map)
end

defimpl DoubleEntryLedger.Occ.Occable, for: DoubleEntryLedger.Event do
  alias Ecto.{Multi, Repo, Changeset}
  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Event.{ErrorMap, IdempotencyKey}
  alias DoubleEntryLedger.Occ.Helper
  alias DoubleEntryLedger.Workers.EventWorker.TransactionEventTransformer

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
  @spec update!(Event.t(), ErrorMap.t(), Repo.t()) :: Event.t()
  def update!(event, error_map, repo) do
    event
    |> Changeset.change(occ_retry_count: error_map.retries, errors: error_map.errors)
    |> repo.update!()
  end

  @spec build_multi(Event.t()) :: Multi.t()
  def build_multi(event) do
    Multi.new()
    |> Multi.put(:occable_item, event)
    |> Multi.insert(:idempotency, fn %{occable_item: %{instance_id: id, event_map: em}} ->
      IdempotencyKey.changeset(id, em)
    end)
    |> Multi.run(:transaction_map, fn _,
                                      %{
                                        occable_item: %{
                                          instance_id: id,
                                          event_map: %{payload: td}
                                        }
                                      } ->
      case TransactionEventTransformer.transaction_data_to_transaction_map(td, id) do
        {:ok, transaction_map} -> {:ok, transaction_map}
        {:error, error} -> {:ok, {:error, error}}
      end
    end)
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

defimpl DoubleEntryLedger.Occ.Occable, for: DoubleEntryLedger.Event.TransactionEventMap do
  alias Ecto.{Multi, Repo}
  alias DoubleEntryLedger.Event.{ErrorMap, TransactionEventMap, IdempotencyKey}
  alias DoubleEntryLedger.Stores.{EventStoreHelper, InstanceStoreHelper}
  alias DoubleEntryLedger.Occ.Helper
  alias DoubleEntryLedger.Workers.EventWorker.TransactionEventTransformer

  @doc """
  Updates an TransactionEventMap during OCC retry cycles.

  For TransactionEventMap, this is a no-op since TransactionEventMaps are transient and
  not stored in the database.

  ## Parameters
    - `event_map` - The TransactionEventMap struct
    - `_error_map` - Contains retry count and errors (unused)
    - `_repo` - Ecto.Repo to use (unused)

  ## Returns
    - The unchanged TransactionEventMap struct
  """
  @spec update!(TransactionEventMap.t(), ErrorMap.t(), Repo.t()) :: TransactionEventMap.t()
  def update!(event_map, _error_map, _repo), do: event_map

  @spec build_multi(TransactionEventMap.t()) :: Multi.t()
  def build_multi(%TransactionEventMap{instance_address: address} = event_map) do
    Multi.new()
    |> Multi.put(:occable_item, event_map)
    |> Multi.one(:_instance, InstanceStoreHelper.build_get_by_address(address))
    |> Multi.insert(:idempotency, fn %{_instance: %{id: id}} ->
      IdempotencyKey.changeset(id, event_map)
    end)
    |> Multi.run(:transaction_map, fn _,
                                      %{
                                        occable_item: %{payload: td},
                                        _instance: %{id: id}
                                      } ->
      case TransactionEventTransformer.transaction_data_to_transaction_map(td, id) do
        {:ok, transaction_map} -> {:ok, transaction_map}
        {:error, error} -> {:ok, {:error, error}}
      end
    end)
  end

  @doc """
  Handles OCC timeout for an TransactionEventMap when maximum retries are reached.

  Creates and stores a permanent Event record from the TransactionEventMap data
  with timeout status, then returns an error tuple.

  ## Parameters
    - `_event_map` - The TransactionEventMap that has reached maximum retries
    - `error_map` - Contains retry count, errors, and created Event
    - `repo` - Ecto.Repo to use for storing the Event

  ## Returns
    - Error tuple containing the created Event and timeout indication
  """
  @spec timed_out(TransactionEventMap.t(), atom(), ErrorMap.t()) ::
          Multi.t()
  def timed_out(
        %{instance_address: address} = event_map,
        name,
        %{save_on_error: true} = error_map
      ) do
    new_event_step = :new_event

    Multi.new()
    |> Multi.one(:_instance, InstanceStoreHelper.build_get_by_address(address))
    |> Multi.insert(new_event_step, fn %{_instance: %{id: id}} ->
      EventStoreHelper.build_create(event_map, id)
    end)
    |> Multi.update(name, fn %{^new_event_step => event} ->
      Helper.occ_timeout_changeset(event, error_map)
    end)
  end

  def timed_out(event_map, name, %{save_on_error: false}) do
    Multi.new()
    |> Multi.put(name, event_map)
  end
end
