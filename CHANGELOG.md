# Changelog

All notable changes to DoubleEntryLedger are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/).

## [0.5.0]

### ⚠️ Breaking changes

- Schema migrations 5–7 replace the three `journal_event_*_links` tables with
  direct foreign keys, add a required `command_queue_items.instance_id`, and
  widen balance/limit columns to `bigint`. Upgrades from 0.4.x must use
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
- Removed `mix load_test`. Source checkouts provide purpose-specific
  `mix load.*` tasks under `MIX_ENV=perf`; these development tasks are not
  included in the Hex package.

### Added

- Opt-in batched command processing for compatible create/update workloads,
  including retry-and-split fallback and per-command telemetry parity.
- Equivalence, stress, mixed-workload, and load-testing coverage for the batched
  and `insert_all` transaction paths.
- Repository-only performance documentation and configurable load-test tasks.
- Batch completion telemetry with per-command span and transaction-lifecycle
  parity.

### Changed

- Journal-event relationships are written synchronously using direct foreign
  keys; the library no longer enqueues an internal linking job or starts an
  external job supervisor.
- Queue claiming, balance-history writes, and transaction persistence have new
  optimized paths. Batching and `insert_all` remain opt-in.
- Package consumers must configure `:insert_path`, `:batch_enabled`, and
  `:batch_size` in their own application. This repository's runtime config is
  not loaded as dependency configuration.

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
