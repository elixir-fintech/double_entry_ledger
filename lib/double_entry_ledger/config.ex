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
        batch_enabled: false,
        max_batch_retries: 3,
        start_command_queue: true,
        insert_path: :legacy,
        max_retries: 5,
        retry_interval: 200,
        batch_size: 8,
        command_queue: [
          poll_interval: 5_000,
          stale_processing_after: 300,
          max_retries: 5,
          base_retry_delay: 30,
          max_retry_delay: 3_600,
          pending_fetch_limit: 64,
          processor_name: "command_queue"
        ]

    * `:batch_enabled` - process claimed commands in batches (default: `false`)
    * `:max_batch_retries` - batch write retries before falling back (default: `3`)
    * `:batch_size` - commands per batch (default: `8`). A `:batch_size` inside
      `:command_queue` is still honoured as a fallback, but only the top-level
      form can be changed at release time.
    * `:start_command_queue` - supervise the queue on this node (default: `true`)
    * `:insert_path` - `:legacy` or `:insert_all` transaction insert path (default: `:legacy`)
    * `:max_retries` - OCC attempts before a command times out (default: `5`)
    * `:retry_interval` - OCC backoff base in milliseconds (default: `200`)
    * `:poll_interval` - monitor poll interval in milliseconds (default: `5_000`)
    * `:stale_processing_after` - seconds before a `:processing` row is stranded (default: `300`)
    * `:max_retries` - queue retries before a command is dead-lettered (default: `5`).
      Distinct from the top-level `:max_retries` above, which counts OCC attempts.
    * `:base_retry_delay` - first retry delay in seconds (default: `30`)
    * `:max_retry_delay` - retry delay cap in seconds (default: `3_600`)
    * `:pending_fetch_limit` - ids fetched per processor round-trip (default: `64`)
    * `:processor_name` - prefix for the generated `processor_id` (default: `"command_queue"`)

  Read at compile time, so changing them requires recompiling this library:
  `:schema_prefix`, `:start_command_queue`, the top-level `:max_retries`, and
  **the whole `:command_queue` list**. `CommandQueue.Scheduling` reads it with
  `Application.compile_env(:double_entry_ledger, :command_queue, [])`, which
  tracks the entire value, so setting any key in it at release time raises a
  compile-environment mismatch on boot — even keys that other modules go on to
  read with `Application.get_env/3`. Everything outside that list
  (`:batch_enabled`, `:batch_size`, `:max_batch_retries`, `:insert_path`,
  `:retry_interval`) is read at runtime.
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
end
