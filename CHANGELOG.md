# Changelog

All notable changes to DoubleEntryLedger are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/).

## [0.6.0]

### ⚠️ Breaking changes

- Schema migration 6 adds `command_queue_leases`. Upgrades from 0.5.x must run
  `DoubleEntryLedger.Migration.up(from: 5)` before starting 0.6.0 nodes.
- Deployment requires stopping every 0.5 node, enqueuers included.
  Migration 6 drops `command_queue_items.processor_version`, which 0.5 writes
  on every queue update and names in every enqueue INSERT, so a 0.5 node of
  any kind fails against the 0.6 schema. Order: stop all 0.5 nodes, take a
  database backup, run `Migration.up(from: 5)`, start 0.6 nodes. Rows left
  `:processing` by 0.5 are rescheduled by the first 0.6 acquisition on each
  ledger. There is no supported mixed-version window.
- Migration 6 is one-way. `Migration.down/1` refuses to cross version 6;
  the only way back to 0.5 is restoring the backup taken before migrating.
- Removed: `processor_version` and the per-row optimistic lock,
  `CommandQueue.OwnershipError` and `{:error, :command_ownership_lost}`,
  `{:error, :command_already_claimed}`, the stale-processing sweep with
  `stale_processing_after`, `Scheduling.stale_processing_commands_query/2`,
  `QueryHelpers.stale_processing/2` and `processing_age_seconds/1`, and
  `:stale_for_seconds` on `[:command, :recovered]`. The ledger lease is the
  only ownership fence; orphaned rows are recovered on acquisition.
- The `:command_queue` key `:stale_processing_after` is gone. It was
  documented in 0.5.0 and read by `InstanceMonitor`'s recovery sweep; that
  sweep no longer exists, so a stale entry in the `:command_queue` list is
  ignored rather than rejected. The queue supervisor logs a warning naming it
  at start-up; a node running with `start_command_queue: false` gets no
  warning. Remove it when upgrading. (The
  reader `CommandQueue.Config.stale_processing_after/0` was introduced and
  removed within this same unreleased cycle, so it never appeared in a
  published release; only the configuration key crosses the 0.5.0 boundary.)
- `CommandQueue.Scheduling.claim_command_for_processing/3` and
  `claim_batch_for_processing/3` take a `CommandQueue.Lease.Grant` instead of
  a `processor_id` string and run in a transaction that locks the ledger's
  lease row.
- `CommandWorker.process_command_with_id/2` accepts a grant or a string. With a
  string it acquires its own lease and may return `{:error, :ledger_owned}`,
  `{:error, :ledger_busy}`, or `{:error, :in_transaction}`; call it outside a
  transaction. Processing may return `{:error, :lease_lost}` or
  `{:error, :lease_busy}`.
- `processor_id` on queue rows identifies a processor process for its whole
  lifetime (`prefix:node:uuid`), not one dispatch. 0.5 stamped a freshly
  generated `prefix_node_integer` on every dispatch.
- `Command` has a virtual `lease_grant` field. `build_schedule_retry_with_reason`
  gains a `retry_delay` option. `InstanceProcessor.start_link/1` requires `:grant`.
- Failure reporting changed shape. The `error` metadata on
  `[:double_entry_ledger, :command, :dead_letter]` is now only the failure
  class, the text of the persisted message before its first `": "`; in 0.5.0 it
  was the full message. Messages can contain fragments of a command's payload,
  and the event reaches whatever exporter the host attached, so the detail no
  longer leaves the database this way. Dead-letter handlers receive less text;
  the full message is on the queue row's `errors`, found by `command_id`.
  `Scheduling.emit_persisted_failure/3`, which is public, now takes an
  `ErrorMap` entry (as built by `ErrorMap.build_error/2`) as its third argument
  instead of a message string; given a string for a failure status it logs an
  error and emits no event. `InstanceMonitor.recover_stale_processing_commands/1`,
  public in 0.5.0, is removed with the sweep it ran.
- `:batch_enabled` and `:batch_size` moved from the top level of the
  `:double_entry_ledger` application environment into the `:command_queue`
  list, alongside `:pending_fetch_limit`. **The top-level spelling is no longer
  read.** It is ignored; the queue supervisor logs a warning naming it at
  start-up, and a node running with `start_command_queue: false` gets no
  warning. A consumer who leaves `config :double_entry_ledger, batch_enabled:
  true` in place gets batching turned off, because the key is not consulted any
  more and the default is `false`; a stale top-level `batch_size` is likewise
  ignored, and the `:command_queue` value or the default of `8` applies. Move
  both keys into the `:command_queue` list
  when upgrading. `config/runtime.exs`'s `BATCH` and `BATCH_SIZE` environment
  overrides now write into that list too.
- All three keys are read and validated by `CommandQueue.Config`.
  `validate!/0` runs both in `CommandQueue.Supervisor.init/1` and in
  `CommandQueue.InstanceProcessor.init/1` — the second because the supervisor
  does not run when `:start_command_queue` is `false` — so a bad value fails
  the start by name instead of surfacing from the dispatch path mid-drain. A
  `:batch_size` of `0` is rejected rather than silently clamped to `1`, and a
  non-integer one is rejected rather than raising from dispatch.
- Both ignored configuration keys in this release are named in the start-up
  log: `:stale_processing_after` left inside the `:command_queue` list, and
  `:batch_enabled` or `:batch_size` left at the top level.
  `CommandQueue.Config.warn_stale_config/0` runs from
  `CommandQueue.Supervisor.init/1`, right after `validate!/0`, and logs at
  `:warning` naming the offending keys and the keys it does know, and points at
  this changelog. It never raises — an ignored key is not a reason to stop a boot,
  and making it one would have been a further breaking change. It does not run
  from `InstanceProcessor.init/1`, which executes once per ledger per drain
  cycle, so a deployment with `start_command_queue: false` gets no warning.
  The four keys the list carries for other readers — `:processor_name` and the
  three compile-time retry keys — are known keys and are never reported.

### Added

- Per-ledger leases in PostgreSQL: one owner of each ledger's queued commands
  across any number of nodes (synchronous `CommandApi.process_from_params/2`
  takes no lease), takeover of an expired lease, and immediate rescheduling of the
  previous owner's in-flight commands. See README "Ownership".
- Configuration: `lease_ttl` (20 s), `lease_lock_timeout_ms` (1000),
  `max_leases_per_node` (`:infinity`), `max_concurrent_acquisitions` (4),
  `coordination_strategy` (`:database_polling`, the only value);
  `CommandQueue.Config.validate!/0` runs from both the queue supervisor and
  every `InstanceProcessor.init/1`.
- `CommandQueue.Coordinator` behaviour with `Coordinator.DatabasePolling`:
  the seam for a future `:erlang_cluster` strategy. Coordinators nominate
  candidates; only the PostgreSQL lease grants ownership.
- Telemetry `[:double_entry_ledger, :lease, :acquired | :renewed | :lost |
  :released]`. `[:command, :recovered]` is now emitted by lease acquisition,
  once for every `:processing` row an acquisition reschedules, and carries
  `reason: :takeover`. That includes an acquisition that inserts a ledger's
  first lease row, so on the first acquisition after upgrading, rows 0.5 left
  `:processing` produce `[:command, :recovered]` with `reason: :takeover` while
  `[:lease, :acquired]` reports `takeover: false`. `Lease.with_grant/3` for fenced
  queue-row writes.
- `[:double_entry_ledger, :instance_processor, :cleanup_stalled]` telemetry
  event. An `InstanceProcessor` that cannot make its post-task cleanup write
  because the lease row stays locked now gives the ledger up after a bounded
  number of retries, emitting this event, rather than retrying forever while
  holding the lease and dispatching nothing. The next owner's acquisition
  reschedules whatever the stalled owner left `:processing` — though not
  necessarily at once, since the same lock holder blocks that acquisition too.
- Opt-in `serialize_enqueue` configuration (runtime, default `false`). When
  enabled, `Stores.CommandStore.create/1` takes a transaction-scoped
  PostgreSQL advisory lock keyed on the instance before the queue item is
  inserted, so queue positions for one ledger are allocated in commit order.
  Enqueues for the same ledger wait on each other; ledgers are locked
  independently except for a possible hash collision. The flag is node-local
  and must be set consistently on every node that enqueues. No migration is
  required. `Config.serialize_enqueue?/0` exposes the flag.

### Changed

- `CommandQueue.Scheduling` now tracks its three compile-time queue keys
  (`:max_retries`, `:base_retry_delay`, `:max_retry_delay`) individually with
  `Application.compile_env/3` on a key path, instead of reading the whole
  `:command_queue` list. Setting any other queue key at release time no longer
  raises a compile-environment mismatch on boot.
- Requires `flop ~> 0.29`. Flop 0.29 turned `Flop.Schema` from a protocol into
  a behaviour, so the paginated schemas now configure it with `use Flop.Schema`
  and `@flop_options` instead of `@derive`. The Flop options themselves are
  unchanged. Applications that depend on Flop directly must also be on 0.29 or
  later.

## [0.5.0]

### ⚠️ Breaking changes

- Schema migration 5 replaces the three `journal_event_*_links` tables with
  direct foreign keys, adds a required `command_queue_items.instance_id`, and
  widens balance/limit columns to `bigint`. It also moves command and queue-item
  timestamps to the PostgreSQL clock, adds a database-generated queue position
  for stable processing order, and adds the transient
  `command_queue_items.retry_delay_seconds` column and queue-trigger rule that
  compute retry deadlines on the database clock. Upgrades from 0.4.x must use
  `DoubleEntryLedger.Migration.up(from: 4)`.
- A mixed 0.4.x/0.5.0 rolling deployment is not supported because old code
  requires the link tables while new code requires the direct foreign keys and
  queue-item `instance_id`. Stop command processing during migration and deploy
  0.5.0 before resuming it.
- Removed the `JournalEventAccountLink`, `JournalEventCommandLink`,
  `JournalEventTransactionLink`, and legacy journal-event link worker modules,
  plus the unused job-runner dependency and supervisor. Applications using the
  job runner for other work must declare and supervise it themselves. Existing
  job-runner tables are not dropped.
- `JournalEvent` now exposes direct `command`, `transaction`, and `account`
  associations. Custom queries and preloads using link associations must be
  updated.
- `CommandQueueItem.changeset/2` now requires `instance_id`.
- `CommandQueueItem.changeset/2` no longer casts `processing_started_at` or
  `processing_completed_at`. PostgreSQL now owns these fields and overwrites
  application-supplied values when queue status changes. Consumers that build
  queue-item changesets or issue raw status updates must use the timestamps
  returned by the database.
- Removed `Command.processing_start_changeset/3` and
  `CommandQueueItem.processing_start_changeset/3`. Claiming a command goes
  through `CommandQueue.Scheduling.claim_command_for_processing/3` or
  `claim_batch_for_processing/3`, which enforce queue status and the retry
  deadline together in one atomic UPDATE. The removed changesets checked
  neither, so a direct caller could claim a command before its retry deadline
  had elapsed.
- Removed `mix load_test`. Source checkouts provide purpose-specific
  `mix load.*` tasks under `MIX_ENV=perf`; these development tasks are not
  included in the Hex package.

### Added

- Opt-in batched command processing for compatible create/update workloads,
  including retry-and-split fallback and per-command telemetry parity.
- Equivalence, stress, mixed-workload, and load-testing coverage for the batched
  and `insert_all` transaction paths.
- Repository-only performance documentation and configurable load-test tasks.
- `:command_queue` option `pending_fetch_limit` (default 64), controlling how
  many queue IDs a processor fetches per database read, and top-level
  `max_batch_retries` (default 3), the number of stale-write retries before a
  batch is split.
- Batch completion telemetry with per-command span and transaction-lifecycle
  parity.
- Recovery of commands stranded in `:processing` by a node that died after
  claiming them. `InstanceMonitor` sweeps rows older than the new
  `:command_queue` option `stale_processing_after` (seconds, default 300),
  measured on the PostgreSQL clock, and sends each through the normal retry or
  dead-letter path under the existing ownership fence, emitting
  `[:double_entry_ledger, :command, :recovered]`.

### Changed

- Journal-event relationships are written synchronously using direct foreign
  keys; the library no longer enqueues an internal linking job or starts an
  external job supervisor.
- Queue claiming, balance-history writes, and transaction persistence have new
  optimized paths. Batching and `insert_all` remain opt-in.
- `commands.inserted_at` plus command-queue insertion, update, processing-start,
  and processing-completion timestamps are generated by PostgreSQL and read
  back after writes, avoiding application-node clock skew.
- Commands are selected using a stable, database-generated queue position
  instead of potentially tied insertion timestamps.
- Retry deadlines are computed by PostgreSQL. Migration 5 adds a transient
  `command_queue_items.retry_delay_seconds` instruction that the queue trigger
  converts into `next_retry_after` on the database clock, and retry eligibility
  reads (`InstanceProcessor`, `InstanceMonitor`, batch claims) compare against
  the database clock as well, so application-node clock skew no longer affects
  retry timing. Consumers must run migration 5.
- Instance command processors are temporary dynamic children, so their exits do
  not consume the shared supervisor's restart budget or terminate processors for
  other instances. `InstanceMonitor` continues to discover claimable work.
- Batched processing now uses the configured consumer repository, preserves
  dependency-wait semantics without hot loops, isolates crashing commands,
  handles partial completion safely, and writes timestamps and error history
  consistently with the legacy path.
- Command completion, retry, dead-letter, and batch-fallback writes are fenced
  by `processor_version`, preventing a stale processor from overwriting work
  after ownership moves to another processor. Ownership loss is returned as the
  expected error `{:error, :command_ownership_lost}` from
  `CommandWorker.process_command_with_id/2`, without account-OCC retries or
  task-crash logging.
- Single-command claims enforce queue status and the retry deadline
  atomically in one UPDATE, sharing the batch claim statement, so a command
  whose `next_retry_after` has not elapsed can no longer be claimed early.
- A successful `CommandStore.create/1` now wakes the local `InstanceMonitor`
  when no processor is registered for the instance, so an idle queue starts
  draining immediately instead of up to `:poll_interval` later. The wake is
  best-effort — it is skipped when the command queue is not running — and
  polling remains the guarantee.
- Package consumers must configure `:insert_path`, `:batch_enabled`, and
  `:batch_size` in their own application. This repository's runtime config is
  not loaded as dependency configuration.

### Security

- `decimal` 2.4.1 ships transitively through Ecto and Money and carries a
  moderate advisory: an unbounded exponent in `Decimal.new/1` allows an
  unauthenticated denial of service
  ([GHSA-rhv4-8758-jx7v](https://github.com/advisories/GHSA-rhv4-8758-jx7v)).
  It is fixed in `decimal` 3.0.0, which Ecto 3.13 cannot use because it
  requires `~> 2.0`, so this release cannot take the fix. Applications that
  build `Decimal` values from untrusted input should bound the exponent before
  parsing. The constraint will be revisited once Ecto supports `decimal` 3.0.
- `postgrex` is updated to 0.22.4, clearing a high-severity channel-name SQL
  injection in `Postgrex.Notifications.listen/3`
  ([GHSA-r73h-97w8-m54h](https://github.com/advisories/GHSA-r73h-97w8-m54h)).
  This library never calls that function, but its requirement was previously
  `>= 0.0.0`, which let a consumer resolve or keep a vulnerable release. The
  requirement is now `>= 0.22.2`, so the patched version is enforced rather
  than merely permitted. Apart from the `decimal` advisory above, every
  advisory reported by `mix deps.audit` reaches the tree only through
  development tooling
  (`bandit`, `plug`, `mint`, `req` via `tidewave`) and none of them appear in a
  production build.

## [0.4.0]

### ⚠️ Breaking changes

Upgrading from 0.3.x requires code and config changes. Each item below
includes the migration step.

1. **Store list functions renamed and re-shaped.** Every `*_list_all_*`
   and `get_all_accounts_*` function was replaced by `list_for_*`, now
   paginated via [Flop](https://hex.pm/packages/flop). Returns changed
   from `[item]` / `{:ok, [item]}` to `{:ok, {[item], %Flop.Meta{}}}`.

   **Migrate:** see the [Function rename map](README.md#function-rename-map)
   and unwrap the result at every call site:

   ```elixir
   # 0.3.x
   accounts = AccountStore.get_all_accounts_by_instance_id(instance_id)
   # 0.4.0
   {:ok, {accounts, _meta}} = AccountStore.list_for_instance(instance_id)
   ```

2. **Pagination: offset → cursor.** List functions take a `flop_params`
   map (`%{first: n, after: cursor, filters: [...]}`), not positional
   `(id, page, per_page)`.

   **Migrate:** translate `page`/`per_page` to Flop's `:first` + `:after`.
   See the Before/After examples in the README.

3. **Supervision shift in BYO-repo mode.** When `:repo` is configured
   (pointing DEL at the host's repo), DEL no longer supervises the command
   queue from its own tree — the consumer must. Leaving this
   out means background work silently never runs.

   **Migrate (BYO-repo only; skip if `:repo` is unset):**

   ```elixir
   # lib/my_app/application.ex
   children = [
     MyApp.Repo,
     # …other children…
   ] ++ DoubleEntryLedger.children()
   ```

### Added

- `config :double_entry_ledger, repo: MyApp.Repo` — point DEL at the
  host application's repo (BYO-repo mode). When unset DEL falls back to
  the shipped `DoubleEntryLedger.Repo`.
- `DoubleEntryLedger.children/0` — child specs for consumer supervisors
  in BYO-repo mode (command queue).
- `DoubleEntryLedger.Telemetry.dashboard_metrics/0` — recommended
  `Telemetry.Metrics` list for Phoenix LiveDashboard.

### Changed

- Pagination is powered by [Flop](https://hex.pm/packages/flop) with
  cursor-based semantics. No consumer `config :flop, repo: …` needed —
  DEL ships its own Flop backend internally.
- `DoubleEntryLedger.Repo` is automatically supervised **only** in
  standalone mode (no `:repo` configured). In BYO-repo mode supervision
  is the consumer's responsibility via `DoubleEntryLedger.children/0`.

### Removed

- All `list_all_*` and `get_all_accounts_*` function names on the store
  modules. See the migration table in the README.
