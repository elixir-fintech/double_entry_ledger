# Performance tests

Reference for the perf tooling that grew out of the throughput
investigation and the multi-command batching work.

This is source-checkout development tooling. The `mix load.*` tasks, their
runtime support, this guide, the equivalence script, and the performance ExUnit
suites are not included in the Hex package. Run the tasks from this repository
with `MIX_ENV=perf` so `config/perf.exs` and `test/performance/` are compiled.

## At a glance

| Tool | Lives in | Invocation | Purpose |
|---|---|---|---|
| `mix load.process` | `test/performance/load.ex` | `MIX_ENV=perf mix load.process C S` | Sliding-window synthetic in-process baseline |
| `mix load.enqueue` | `test/performance/load.ex` | `MIX_ENV=perf mix load.enqueue C S` | Producer-only sliding-window load |
| `mix load.drain` | `test/performance/load.ex` | `MIX_ENV=perf mix load.drain N` | K=1 single-instance consumer drain (creates only) |
| `mix load.mixed_drain` | `test/performance/load.ex` | `MIX_ENV=perf mix load.mixed_drain C U` | K=1 mixed-workload drain (creates + updates) |
| `mix load.multi_drain` | `test/performance/load.ex` | `MIX_ENV=perf mix load.multi_drain N K` | Multi-instance scaling drain |
| `batch_equivalence.exs` | `test/performance/batch_equivalence.exs` | `MIX_ENV=equiv mix run --no-start ...` | Path-A vs Path-B equivalence (one-shot) |
| Equivalence property test | `test/lib/batch_processor_equivalence_test.exs` | `mix test` (auto) | CI-runnable random-corpus equivalence |
| Stress test | same file as above | `mix test` (auto) | High-contention 100-cmd / 2-account regression |

## Mix environments

Three Mix envs are used; each has its own database so they don't
interfere with each other:

| Env | DB | Purpose |
|---|---|---|
| `:test` | `double_entry_ledger_repo_test` | ExUnit (`mix test`). Sandboxed. |
| `:perf` | `double_entry_ledger_repo_performance` | Load tests. `synchronous_commit: off`, `pool_size: 60`, `start_command_queue: false`. |
| `:equiv` | `double_entry_ledger_repo_equivalence` | Equivalence script. Separate so its leftover rows don't pollute the test DB. |

The load tasks drop/create/migrate the perf DB on every invocation —
each run starts fresh. The equivalence script does the same for the
equiv DB on first run; subsequent runs reuse it.

## Mix tasks

### `mix load.process C S`

```bash
MIX_ENV=perf mix load.process 4 10
```

Synthetic baseline. Spawns `C` worker processes (sliding window) that
each loop calling `CommandWorker.process_new_command/1` directly for
`S` seconds. Bypasses both the queue AND the public producer API.

Reports operations/second. **Useful as an upper bound** on per-call
processing cost; **not a model of production traffic** — real callers
hit the queue.

### `mix load.enqueue C S`

```bash
MIX_ENV=perf mix load.enqueue 8 10
```

Producer-only. Spawns `C` workers calling
`CommandApi.create_from_params/1` (the real production producer path)
for `S` seconds. Measures the cost of getting commands into the
queue — validates payload, hashes idempotency, inserts the `Command` +
`CommandQueueItem` rows. Subsequent processing not measured because
`start_command_queue: false` in `:perf`.

Useful for sizing producer throughput in isolation.

### `mix load.drain N`

```bash
MIX_ENV=perf mix load.drain 10000
```

K=1 single-instance consumer drain. **The primary single-instance perf
test for the batched-write work.**

Pre-fills the queue with `N` `:create_transaction` commands via the
producer path (parallelized but **not** measured), then starts ONE
`InstanceProcessor` and times the drain. Reports tps + latency
distribution.

Honors:
- `INSERT_PATH=insert_all` — flips `CreateTransactionCommand` to the
  insert_all path (Layer 1 of the perf work, committed earlier).
- `BATCH=on` — enables `BatchProcessor.run_batch/2` for compatible transaction
  commands. Account commands remain on the single-command path.
- `BATCH_SIZE=N` — overrides the default batch size of 8 when
  `BATCH=on`. Useful for M-sweep characterizations.

### `mix load.mixed_drain C U`

```bash
MIX_ENV=perf mix load.mixed_drain 5000 5000
```

K=1 mixed-workload drain. **The primary perf gate for the
update-batching work (Phase B).** Pairs with `load.drain` (which is
create-only).

Four-phase: pre-fills `C` `:pending` creates with deterministic
source_idempks; drains them (not measured); pre-fills `U` updates
targeting the first `U` creates (random new status: `:posted`,
`:pending`, or `:archived`); drains the updates (MEASURED). Reports
tps = `U / phase4_elapsed`. Use `C == U` for the 50/50 corpus the
B7 gate measures (`≥600 tps per instance, ≥300%` improvement vs
legacy mixed baseline).

Honors:
- `BATCH=on` — enables `BatchProcessor.run_batch/2`. With `:update_transaction`
  now batchable (Phase B), mixed batches no longer fall back per-cmd.
- `BATCH_SIZE=N` — overrides the default batch size of 8 when
  `BATCH=on`. Larger sizes amortize fixed CTE-bundle overhead.

### `mix load.multi_drain N K`

```bash
MIX_ENV=perf mix load.multi_drain 4 5000
```

Multi-instance scaling. Spawns `N` `InstanceProcessor`s in parallel,
each draining its own `K` pre-filled commands against its own
non-overlapping accounts. Reports per-instance + aggregate tps, plus
scaling efficiency vs the K=1 baseline.

Useful for validating that the system actually scales horizontally
across instances (it does, until the shared Postgres becomes the
bottleneck around N=8 on a single host).

## Equivalence script

```bash
MIX_ENV=equiv mix run --no-start test/performance/batch_equivalence.exs
```

One-shot comparison driver. Generates `N` random valid
`:create_transaction` commands (default 200, override via
`BATCH_EQ_N`), runs them through:
- **Path A**: legacy `CreateTransactionCommand.process/2` with
  `INSERT_PATH=insert_all`.
- **Path B**: `BatchProcessor.run_batch/2`.

After each path, snapshots the DB state (per-account final state,
queue state, total row counts, per-(account,type) entry sums) and
diffs. Exits 0 on equivalence, non-zero on divergence. Refuses to run
under any MIX_ENV other than `:equiv` so it can't pollute other
databases.

Side benefit: prints both paths' wall-times so you get a rough
speed comparison out of the box.

## ExUnit equivalence + stress tests

`test/lib/batch_processor_equivalence_test.exs` — runs with `mix test`.
Two parts:

1. **Property test**: `StreamData` generates random valid command
   sequences (5–30 commands per iteration, 20 iterations); each
   sequence runs via both paths and the DB state is asserted equal.
   Locks in equivalence across CI builds.

2. **Stress test**: 100 commands hitting only 2 accounts (high
   contention). Both paths produce identical state, and Path B (batched)
   runs at least 20% faster than Path A. Catches regressions in either
   the OCC-retry path or the batched fold under contention.

Stream_data is a test-only dep (also available in `:equiv`).

## Environment variables

| Variable | Effect |
|---|---|
| `INSERT_PATH=insert_all` | Switches `CreateTransactionCommand.build_transaction/4` from the legacy cascade to the `Repo.insert_all`-based path for the run. |
| `BATCH=on` | Enables `BatchProcessor.run_batch/2` in the `InstanceProcessor`. Default `false`. |
| `BATCH_SIZE=N` | Overrides the `InstanceProcessor` batch size for repository-local runs. Defaults to 8 if unset. |
| `BATCH_EQ_N=N` | Number of commands the equivalence script generates per path. Default 200. |
| `PROFILE=1` | (Currently commented-out in `load.ex`.) When uncommented, wraps the drain phase in an `:eprof` profiling session. |

## Typical observed numbers (single host, quiet machine)

These are reference points, not contracts. Numbers vary with machine
state.

### K=1 single-instance drain (`mix load.drain 10000`)

| Path | tps | Mean latency |
|---|---|---|
| legacy (default) | ~230 | ~3.0 ms |
| `INSERT_PATH=insert_all` | ~260 | ~2.7 ms |
| `BATCH=on` M=8 | ~700 | ~1.2 ms |
| `BATCH=on` M=16 | ~830 | ~1.0 ms |
| `BATCH=on` M=32 | ~910 | ~960 µs |
| `BATCH=on` M=64 | ~1100 | ~790 µs |
| `BATCH=on` M=128 | regresses (breaking point) | — |

### Multi-instance drain (`mix load.multi_drain N 5000`)

`BATCH=on BATCH_SIZE=64`, pool=60:

| N | Aggregate tps | Per-instance tps |
|---|---|---|
| 1 | ~1000 | ~1000 |
| 2 | ~1600 | ~830 |
| 4 | ~2400 | ~600 |
| 8 | ~2700 | ~330 |
| 16 | ~2200 | (lower) |

Ceiling around N=8 — Postgres CPU/disk on a single host saturates.
Beyond requires DB-side scaling (bigger host, PgBouncer, sharding).

## Schema evolution that matters for perf

Several migrations were driven by perf findings:

| Version | Change | Why |
|---|---|---|
| v4 | Compound `(entry_id, inserted_at)` index on `balance_history_entries` | Removed sequential scans on entry lookups |
| v5 | Replaced three journal-event link tables and the linking job with direct foreign keys | Removed link-table and background-job write amplification |
| v6 | Denormalized `instance_id` onto `command_queue_items` + partial in-flight index | Fixed O(N²) drain in `find_next_command_ids` |
| v7 | Widened `accounts.{available, negative_limit}` + `balance_history_entries.available` from `int4` to `bigint` | Original `int4` capped balances at ~2.1B; load tests at N≥30000 hit overflow, and real ledgers would too |

The `test/double_entry_ledger/migration_test.exs` file asserts the
landed state of each.

## Profiling

`test/performance/load.ex` has eprof scaffolding commented out around
the drain phase. Uncomment the four `:eprof.*` lines (and the
`Application.ensure_all_started(:tools)` line) to capture a per-process
profile. Output is verbose — pipe to a file and bucket by module.

`:tools` is in `extra_applications` for `:perf` via `mix.exs` so eprof
is available.

## See also

- [Asynchronous processing](AsynchronousEventProcessing.md) for production
  queue and batching configuration
- [Telemetry](Telemetry.md) for batch measurements and per-command span parity
- `DoubleEntryLedger.Migration` for the schema-version history
