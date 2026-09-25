defmodule DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling do
  @moduledoc """
  Every node polls PostgreSQL for ledgers with work and no live lease, and
  competes for them through `Lease.acquire/4`. A reservation is the instance
  id; it is refused while this node already runs the ledger (local Registry)
  or holds a reservation for it. After a monitor restart the reservation map
  is empty; running processors stay excluded through the Registry, and a
  duplicate attempt for a surviving acquisition task is answered by
  `acquire/4` with `:held` or `:busy`.

  Only the KEYS of `reserved` do any work. The `task_ref` and `processor_pid`
  recorded against each one are advisory, kept because the behaviour announces
  both ends of a reservation's lifetime; see the `Coordinator` moduledoc.
  """
  @behaviour DoubleEntryLedger.CommandQueue.Coordinator

  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  @impl true
  def init(_opts), do: %{reserved: %{}}

  @impl true
  def candidates(state) do
    ids =
      Scheduling.instances_with_processable_commands_query()
      |> Repo.all()
      |> Enum.reject(&excluded?(&1, state))

    {ids, state}
  end

  @impl true
  def reserve(instance_id, state) do
    if excluded?(instance_id, state) do
      {:skip, state}
    else
      {:ok, instance_id,
       put_in(state, [:reserved, instance_id], %{task_ref: nil, processor_pid: nil})}
    end
  end

  @impl true
  def acquisition_started(instance_id, ref, state),
    do: put_in(state, [:reserved, instance_id, :task_ref], ref)

  @impl true
  def processor_started(instance_id, pid, state),
    do: put_in(state, [:reserved, instance_id, :processor_pid], pid)

  @impl true
  def release(instance_id, state),
    do: %{state | reserved: Map.delete(state.reserved, instance_id)}

  defp excluded?(instance_id, %{reserved: reserved}) do
    Map.has_key?(reserved, instance_id) or
      Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance_id) != []
  end
end
