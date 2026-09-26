defmodule DoubleEntryLedger.CommandQueue.Config do
  @moduledoc """
  Reads and validates the `:command_queue` configuration list.

  `CommandQueue.Supervisor.init/1` calls `validate!/0` before starting any
  child, so a bad value fails the supervisor start with one clear error, and
  then `warn_stale_config/0`, which logs — never raises — about configuration
  this release stopped reading.

  Keys and defaults:

    * `:poll_interval` - monitor poll interval in milliseconds (5_000)
    * `:lease_ttl` - seconds a lease lives without a refresh (20)
    * `:lease_lock_timeout_ms` - wait for the lease row lock (1_000)
    * `:max_leases_per_node` - processors this node may run at once (`:infinity`)
    * `:max_concurrent_acquisitions` - acquisition tasks in flight per node,
      also `AcquireSupervisor`'s `max_children` (4)
    * `:coordination_strategy` - which `Coordinator` decides what this node
      attempts; `:database_polling` is the only value in this release
    * `:pending_fetch_limit` - command ids a processor buffers per database
      round-trip (64)
    * `:batch_enabled` - process claimed commands in batches (false). Read per
      dispatch round, so it is a live switch.
    * `:batch_size` - commands per batch (8)

  Four more keys live in the same list but are read elsewhere, so they are not
  validated here and must not be reported as unknown: `:max_retries`,
  `:base_retry_delay` and `:max_retry_delay`, which `CommandQueue.Scheduling`
  bakes in with `Application.compile_env/3` on a key path, and
  `:processor_name`, the owner-id prefix `CommandQueue.Lease.owner_id/1` reads.
  `known_keys/0` is the union.
  """

  @defaults [
    poll_interval: 5_000,
    lease_ttl: 20,
    lease_lock_timeout_ms: 1_000,
    max_leases_per_node: :infinity,
    max_concurrent_acquisitions: 4,
    coordination_strategy: :database_polling,
    pending_fetch_limit: 64,
    batch_enabled: false,
    batch_size: 8
  ]

  # Keys of the :command_queue list that are legitimately configured but NOT
  # read through this module. Each has exactly one reader, named here so the
  # unknown-key warning cannot flag correct configuration:
  #
  #   :max_retries, :base_retry_delay, :max_retry_delay —
  #     CommandQueue.Scheduling, `Application.compile_env/3` on a key path.
  #     Compiled into the retry maths, which is why this module neither reads
  #     nor validates them.
  #   :processor_name —
  #     CommandQueue.Lease.owner_id/1, the prefix of the generated owner id.
  #
  # `command_queue_known_keys_test.exs` scans lib/ for every key read out of
  # the list and fails if one is missing from `known_keys/0`.
  @external_keys [:max_retries, :base_retry_delay, :max_retry_delay, :processor_name]

  @known_keys Keyword.keys(@defaults) ++ @external_keys

  # Keys that moved INTO the :command_queue list in 0.6.0 and are no longer
  # read from the top level of the :double_entry_ledger environment. A stale
  # top-level spelling is silently ignored, which is what this warns about.
  # `:pending_fetch_limit` is deliberately absent: it was already in the list
  # in 0.5.0 and was never read from the top level.
  @relocated_keys [:batch_enabled, :batch_size]

  # Strategy atom -> Coordinator implementation. The only entry in this
  # release; :erlang_cluster is a future spec (design §9).
  @coordinators %{database_polling: DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling}

  require Logger

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

  @spec pending_fetch_limit() :: pos_integer()
  def pending_fetch_limit, do: get(:pending_fetch_limit)

  @spec batch_enabled?() :: boolean()
  def batch_enabled?, do: get(:batch_enabled)

  @spec batch_size() :: pos_integer()
  def batch_size, do: get(:batch_size)

  @doc "The `Coordinator` implementation selected by `:coordination_strategy`."
  @spec coordinator() :: module()
  def coordinator, do: Map.fetch!(@coordinators, coordination_strategy())

  @doc """
  Every key the `:command_queue` list may legitimately carry: the nine this
  module reads plus the four read by `CommandQueue.Scheduling` and
  `CommandQueue.Lease`.
  """
  @spec known_keys() :: [atom()]
  def known_keys, do: @known_keys

  @doc """
  Logs a warning about command-queue configuration this release stopped
  reading, and returns `:ok`.

  Two silent upgrade hazards, one message each. Both messages name the
  offending keys from the environment rather than from a hard-coded list, so
  they stay correct as keys come and go, and so this module does not have to
  mention a mechanism it removed (`unified_fencing_test.exs` enforces that).

    * a key in the `:command_queue` list that is not in `known_keys/0` — the
      key removed in 0.6.0 is the one a 0.5 consumer is most likely to still
      have;
    * `:batch_enabled` or `:batch_size` still set at the TOP level of the
      `:double_entry_ledger` environment, where 0.5 read them and 0.6 does
      not. That one cannot be seen from inside the list, which is why it is a
      separate check.

  Warns rather than raises: an ignored key is not a reason to stop a boot, and
  turning it into one would be a further breaking change in the same release.
  Never raises, whatever the environment holds — a malformed list yields no
  keys rather than an exception.

  Called from `CommandQueue.Supervisor.init/1` and NOT from `validate!/0`,
  which also runs in `CommandQueue.InstanceProcessor.init/1`: a processor
  starts once per ledger per drain cycle, so warning there would repeat a
  boot-time diagnostic indefinitely on a busy node.
  """
  @spec warn_stale_config() :: :ok
  def warn_stale_config do
    warn_unknown_keys(unknown_keys())
    warn_relocated_keys(relocated_keys_at_top_level())
  end

  defp warn_unknown_keys([]), do: :ok

  defp warn_unknown_keys(keys) do
    Logger.warning(
      "ignoring unknown :command_queue configuration #{inspect(keys)}: " <>
        "DoubleEntryLedger does not read #{plural(keys)} and #{plural_verb(keys)} no effect. " <>
        "Keys the command queue reads: #{inspect(@known_keys)}. " <>
        "See the 0.6.0 CHANGELOG for the keys this release removed."
    )
  end

  defp warn_relocated_keys([]), do: :ok

  defp warn_relocated_keys(keys) do
    Logger.warning(
      "ignoring #{inspect(keys)} at the top level of the :double_entry_ledger " <>
        "environment: 0.6.0 reads #{plural(keys)} only inside the :command_queue list. " <>
        "Move #{plural(keys)} into `config :double_entry_ledger, :command_queue, ...`. " <>
        "The top-level value is ignored; the :command_queue value applies if set, " <>
        "otherwise the default (#{defaults_text(keys)})."
    )
  end

  defp defaults_text(keys) do
    @defaults
    |> Keyword.take(keys)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)
  end

  defp plural([_one]), do: "it"
  defp plural(_many), do: "them"

  defp plural_verb([_one]), do: "it has"
  defp plural_verb(_many), do: "they have"

  defp unknown_keys do
    :double_entry_ledger
    |> Application.get_env(:command_queue, [])
    |> configured_keys()
    |> Enum.reject(&(&1 in @known_keys))
  end

  defp relocated_keys_at_top_level do
    Enum.filter(@relocated_keys, fn key ->
      Application.get_env(:double_entry_ledger, key) != nil
    end)
  end

  # Tolerant of anything: a non-keyword value yields no keys rather than
  # raising, because this is a diagnostic and `validate!/0` is what is allowed
  # to fail a start.
  defp configured_keys(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      {key, _value} when is_atom(key) -> [key]
      _other -> []
    end)
    |> Enum.uniq()
  end

  @doc "Raises `ArgumentError` naming the first invalid key; returns `:ok`."
  @spec validate!() :: :ok
  def validate! do
    positive_integer!(:poll_interval)
    positive_integer!(:lease_ttl)
    positive_integer!(:lease_lock_timeout_ms)
    positive_integer_or_infinity!(:max_leases_per_node)
    positive_integer!(:max_concurrent_acquisitions)
    known_strategy!(:coordination_strategy)
    positive_integer!(:pending_fetch_limit)
    boolean!(:batch_enabled)
    positive_integer!(:batch_size)
    :ok
  end

  defp boolean!(key) do
    value = get(key)

    unless is_boolean(value) do
      raise ArgumentError, ":#{key} must be a boolean, got: #{inspect(value)}"
    end
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
