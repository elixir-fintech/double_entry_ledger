defmodule DoubleEntryLedger.CommandQueue.Config do
  @moduledoc """
  Reads and validates the `:command_queue` configuration list.

  `CommandQueue.Supervisor.init/1` calls `validate!/0` before starting any
  child, so a bad value fails the supervisor start with one clear error.

  Keys and defaults:

    * `:poll_interval` - monitor poll interval in milliseconds (5_000)
    * `:lease_ttl` - seconds a lease lives without a refresh (20)
    * `:lease_lock_timeout_ms` - wait for the lease row lock (1_000)
    * `:max_leases_per_node` - processors this node may run at once (`:infinity`)
    * `:max_concurrent_acquisitions` - acquisition tasks in flight per node,
      also `AcquireSupervisor`'s `max_children` (4)
    * `:coordination_strategy` - which `Coordinator` decides what this node
      attempts; `:database_polling` is the only value in this release
  """

  @defaults [
    poll_interval: 5_000,
    lease_ttl: 20,
    lease_lock_timeout_ms: 1_000,
    max_leases_per_node: :infinity,
    max_concurrent_acquisitions: 4,
    coordination_strategy: :database_polling
  ]

  # Strategy atom -> Coordinator implementation. The only entry in this
  # release; :erlang_cluster is a future spec (design §9).
  @coordinators %{database_polling: DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling}

  @spec poll_interval() :: pos_integer()
  def poll_interval, do: get(:poll_interval)

  @spec lease_ttl() :: pos_integer()
  def lease_ttl, do: get(:lease_ttl)

  @spec lease_lock_timeout_ms() :: pos_integer()
  def lease_lock_timeout_ms, do: get(:lease_lock_timeout_ms)

  @spec max_leases_per_node() :: pos_integer() | :infinity
  def max_leases_per_node, do: get(:max_leases_per_node)

  @spec max_concurrent_acquisitions() :: pos_integer()
  def max_concurrent_acquisitions, do: get(:max_concurrent_acquisitions)

  @spec coordination_strategy() :: atom()
  def coordination_strategy, do: get(:coordination_strategy)

  @doc "The `Coordinator` implementation selected by `:coordination_strategy`."
  @spec coordinator() :: module()
  def coordinator, do: Map.fetch!(@coordinators, coordination_strategy())

  @doc "Raises `ArgumentError` naming the first invalid key; returns `:ok`."
  @spec validate!() :: :ok
  def validate! do
    positive_integer!(:poll_interval)
    positive_integer!(:lease_ttl)
    positive_integer!(:lease_lock_timeout_ms)
    positive_integer_or_infinity!(:max_leases_per_node)
    positive_integer!(:max_concurrent_acquisitions)
    known_strategy!(:coordination_strategy)
    :ok
  end

  defp known_strategy!(key) do
    value = get(key)

    unless Map.has_key?(@coordinators, value) do
      raise ArgumentError,
            ":#{key} must be one of #{inspect(Map.keys(@coordinators))}, got: #{inspect(value)}"
    end
  end

  defp get(key) do
    :double_entry_ledger
    |> Application.get_env(:command_queue, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  defp positive_integer!(key) do
    value = get(key)

    unless is_integer(value) and value > 0 do
      raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp positive_integer_or_infinity!(key) do
    value = get(key)

    unless value == :infinity or (is_integer(value) and value > 0) do
      raise ArgumentError,
            ":#{key} must be a positive integer or :infinity, got: #{inspect(value)}"
    end
  end
end
