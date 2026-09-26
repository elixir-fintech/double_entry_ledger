defmodule DoubleEntryLedger.Config do
  @moduledoc """
  Access to consumer-supplied configuration.

  Consumers typically set:

      config :double_entry_ledger,
        repo: MyApp.Repo,
        schema_prefix: "my_ledger",
        idempotency_secret: System.get_env("DEL_IDEMPOTENCY_SECRET")

  When `:repo` is not set the library falls back to the shipped
  `DoubleEntryLedger.Repo` module (useful when running the library
  standalone for tests or demos). In that fallback mode consumers must
  configure `DoubleEntryLedger.Repo` per-env themselves.

  `:schema_prefix` controls the Postgres schema in which DEL's tables
  live. It defaults to `"double_entry_ledger"`.

  ## Command queue configuration

      config :double_entry_ledger,
        max_batch_retries: 3,
        start_command_queue: true,
        insert_path: :legacy,
        serialize_enqueue: false,
        max_retries: 5,
        retry_interval: 200,
        command_queue: [
          poll_interval: 5_000,
          max_retries: 5,
          base_retry_delay: 30,
          max_retry_delay: 3_600,
          pending_fetch_limit: 64,
          batch_enabled: false,
          batch_size: 8,
          lease_ttl: 20,
          lease_lock_timeout_ms: 1_000,
          max_leases_per_node: :infinity,
          max_concurrent_acquisitions: 4,
          coordination_strategy: :database_polling,
          processor_name: "command_queue"
        ]

    * `:max_batch_retries` - batch write retries before falling back (default: `3`)
    * `:start_command_queue` - supervise the queue on this node (default: `true`)
    * `:insert_path` - `:legacy` or `:insert_all` transaction insert path (default: `:legacy`)
    * `:serialize_enqueue` - take a transaction-scoped PostgreSQL advisory lock
      per ledger in `Stores.CommandStore.create/1`, so queue positions for one
      ledger are allocated in commit order (default: `false`). Enqueues for the
      same ledger then wait on each other; ledgers are locked independently
      except for a possible 32-bit hash collision, which only adds waiting.
      Node-local: every node that enqueues commands must set the same value,
      or the commit-order guarantee does not hold.
    * `:max_retries` - OCC attempts before a command times out (default: `5`)
    * `:retry_interval` - OCC backoff base in milliseconds (default: `200`)
    * `:poll_interval` - monitor poll interval in milliseconds (default: `5_000`)
    * `:max_retries` - queue retries before a command is dead-lettered (default: `5`).
      Distinct from the top-level `:max_retries` above, which counts OCC attempts.
    * `:base_retry_delay` - first retry delay in seconds (default: `30`)
    * `:max_retry_delay` - retry delay cap in seconds (default: `3_600`)
    * `:pending_fetch_limit` - ids fetched per processor round-trip (default: `64`)
    * `:batch_enabled` - process claimed commands in batches (default: `false`).
      Read per dispatch round, so it is a live switch.
    * `:batch_size` - commands per batch (default: `8`)
    * `:lease_ttl` - seconds a ledger lease lives without a refresh (default: `20`).
      Also the failover budget: a dead node's ledgers cannot be taken over
      before its leases expire.
    * `:lease_lock_timeout_ms` - how long a writer waits for the lease row lock
      before reporting contention (default: `1_000`)
    * `:max_leases_per_node` - ledgers this node may work at once, enforced as
      `InstanceSupervisor`'s `max_children` (default: `:infinity`)
    * `:max_concurrent_acquisitions` - lease acquisitions in flight on this
      node, enforced as `AcquireSupervisor`'s `max_children` (default: `4`)
    * `:coordination_strategy` - which `CommandQueue.Coordinator` decides what
      this node attempts. `:database_polling` is the only value in this
      release; anything else is rejected by `CommandQueue.Config.validate!/0`
      (default:
      `:database_polling`)
    * `:processor_name` - prefix of the generated owner id, which is
      `"prefix:node:uuid"` and is stamped on queue rows as `processor_id`
      (default: `"command_queue"`)

  `CommandQueue.Config` is the single reader for the queue keys it owns, and
  its `validate!/0` rejects a bad value by name at start-up rather than letting
  it surface later from whatever code path happens to read it first. It runs in
  `CommandQueue.Supervisor.init/1` before any child starts, and again in
  `CommandQueue.InstanceProcessor.init/1`, because the supervisor does not run
  at all when `:start_command_queue` is `false`. `:processor_name` and the
  three compile-time retry keys below are not among the keys it checks.
  `CommandQueue.Config.warn_stale_config/0`, called by the supervisor straight
  after, logs about keys this release stopped reading; it warns rather than
  raising and runs once per queue start.

  Read at compile time, so changing them requires recompiling this library:
  `:schema_prefix`, `:start_command_queue`, the top-level `:max_retries`, and
  the three `:command_queue` keys `CommandQueue.Scheduling` bakes into its
  retry maths — `:max_retries`, `:base_retry_delay` and `:max_retry_delay`.
  Those three are tracked individually (`compile_env/3` on a key path), so
  setting any OTHER queue key at release time is fine; reading the list as a
  whole would have tracked all of them and raised a compile-environment
  mismatch on boot. Everything else, inside the list and outside it
  (`:max_batch_retries`, `:insert_path`, `:serialize_enqueue`,
  `:retry_interval`), is read at runtime.
  """

  @schema_prefix Application.compile_env(
                   :double_entry_ledger,
                   :schema_prefix,
                   "double_entry_ledger"
                 )

  @doc """
  Returns the configured Ecto repo module.

  Read at runtime (not compile time) so consumer apps can override via
  `config :double_entry_ledger, repo: MyApp.Repo` without forcing a
  recompile of this library. Mix's `compile_env` tracking does not reach
  into path/hex deps reliably, so runtime resolution is safer here.
  """
  @spec repo() :: module()
  def repo, do: Application.get_env(:double_entry_ledger, :repo, DoubleEntryLedger.Repo)

  @doc """
  Returns the Postgres schema prefix used by DEL's tables.

  Baked in at compile time because Ecto's `@schema_prefix` must be a
  literal. Consumers overriding `:schema_prefix` must force a recompile
  of this library (`mix deps.compile double_entry_ledger --force`) for
  the change to take effect in the schema modules.
  """
  @spec schema_prefix() :: String.t()
  def schema_prefix, do: @schema_prefix

  @doc """
  Whether `Stores.CommandStore.create/1` serializes enqueues per ledger.

  Read at runtime. Defaults to `false`.
  """
  @spec serialize_enqueue?() :: boolean()
  def serialize_enqueue?,
    do: Application.get_env(:double_entry_ledger, :serialize_enqueue, false) == true
end
