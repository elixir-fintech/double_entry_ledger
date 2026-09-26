# DoubleEntryLedger

**[![Elixir CI](https://github.com/elixir-fintech/double_entry_ledger/actions/workflows/elixir.yml/badge.svg)](https://github.com/elixir-fintech/double_entry_ledger/actions/workflows/elixir.yml)**

DoubleEntryLedger is an event sourced, multi-tenant double entry accounting engine for Elixir and PostgreSQL. It provides typed accounts, signed amount APIs, pending/posting flows, an optimistic-concurrency command queue, and a fully auditable journal so you can embed reliable ledgering without rebuilding the fundamentals.

## Highlights

- Multi tenant ledger instances with typed accounts (asset/liability/equity/revenue/expense) and [Money](https://hexdocs.pm/money) backed multi currency support.
- Signed amount API converts intent into the correct debit or credit entry and enforces balanced transactions per currency.
- Immutable `Command`, `JournalEvent`, and `BalanceHistoryEntry` records plus idempotency keys give a complete audit trail.
- Background command queue with a per-ledger PostgreSQL ownership lease, OCC, exponential retries, per-instance processors, and idempotency controls makes command processing safe to retry across any number of nodes.
- Pending vs. posted projections with automatic `available` balances support holds, authorizations, and delayed settlements.
- Rich stores and APIs (`InstanceStore`, `AccountStore`, `TransactionStore`, `CommandStore`, `CommandApi`, `JournalEventStore`) keep ledger interactions safe and consistent.
- Everything lives inside the configurable `double_entry_ledger` schema so it coexists peacefully with your application tables.

## System Overview

### Instances & Accounts

`DoubleEntryLedger.Stores.InstanceStore` (`lib/double_entry_ledger/stores/instance_store.ex`) defines isolation boundaries. Each instance owns its own configuration, accounts, and transactions. `DoubleEntryLedger.Stores.AccountStore` validates account type, currency, addressing format, and maintains embedded `posted`, `pending`, and `available` balance structs. Helpers in `DoubleEntryLedger.Types` and `DoubleEntryLedger.Utils.Currency` encapsulate allowed values.

### Commands, Journal Events & Transactions

External requests enter through `DoubleEntryLedger.Apis.CommandApi` (`lib/double_entry_ledger/apis/command_api.ex`). Requests are normalized into `TransactionCommandMap` or `AccountCommandMap` structs, hashed for idempotency, and saved as immutable `Command` records (`lib/double_entry_ledger/schemas/command.ex`). Successful processing creates `JournalEvent` records plus `Transaction` + `Entry` rows. Each journal event stores direct foreign keys to its command and related transaction or account. Query stores such as `DoubleEntryLedger.Stores.TransactionStore` and `DoubleEntryLedger.Stores.JournalEventStore` expose read models by instance, account, or transaction.

### Queues, Workers & OCC

The command queue (`lib/double_entry_ledger/command_queue`) polls for pending commands via `InstanceMonitor`, acquires a `CommandQueue.Lease` for each ledger it is going to work, starts one `InstanceProcessor` per leased ledger, and uses `CommandQueue.Scheduling` to claim, retry, or dead-letter work under that lease. The transaction-related workers under `lib/double_entry_ledger/workers/command_worker` implement `DoubleEntryLedger.Occ.Processor`, translating event maps into `Ecto.Multi` workflows that retry on `Ecto.StaleEntryError`. Journal-event relationships are written synchronously with the journal event; there is no internal linking job in 0.6.0.

### Balances & Audit Trails

Each transaction updates `Account` projections plus immutable `BalanceHistoryEntry` snapshots, enabling temporal queries and reconciliation. Instances can be validated with `Instance.validate_account_balances/1`, ensuring posted and pending debits/credits remain equal. Direct `command_id`, `transaction_id`, and `account_id` foreign keys on journal events provide traceability from the original request to the final projection.

### Idempotency & Isolation

Every command requires a `source` and `source_idempk` (plus `update_idempk` for updates). These keys are hashed via `DoubleEntryLedger.Command.IdempotencyKey` to prevent duplicates, while `PendingTransactionLookup` enforces a single open update chain for each pending transaction. All tables live inside a dedicated Postgres schema (`double_entry_ledger` by default, overridable via `config :double_entry_ledger, schema_prefix: …`), so migrations never clash with your application schema.

## Requirements

- Elixir `~> 1.15` and OTP 26.
- PostgreSQL 14+ with permission to create the `double_entry_ledger` schema.
- Access to run Mix tasks (`mix ecto.create`, `mix ecto.migrate`, `mix test`, etc.).
- Runtime dependencies are installed automatically through Hex. Credo, Dialyzer, and other development tools are only needed when working from a source checkout.

## Installation

### 1. Add the dependency

```elixir
def deps do
  [
    {:double_entry_ledger, "~> 0.6.0"}
  ]
end
```

Run `mix deps.get` after updating `mix.exs`.

### 2. Configure the application

Most consumers point DoubleEntryLedger at their own Ecto repo so the
library shares one connection pool (and one Ecto sandbox in tests):

```elixir
# config/config.exs
import Config

config :double_entry_ledger,
  repo: MyApp.Repo,
  idempotency_secret: System.fetch_env!("LEDGER_IDEMPOTENCY_SECRET"),
  start_command_queue: true,
  insert_path: :legacy,
  serialize_enqueue: false,
  max_batch_retries: 3,
  max_retries: 5,
  retry_interval: 200

config :double_entry_ledger, :command_queue,
  poll_interval: 5_000,
  pending_fetch_limit: 64,
  batch_enabled: false,
  batch_size: 8,
  max_retries: 5,
  base_retry_delay: 30,
  max_retry_delay: 3_600,
  lease_ttl: 20,                    # seconds a ledger lease lives without a refresh
  lease_lock_timeout_ms: 1_000,     # how long a writer waits for the lease row lock
  max_leases_per_node: :infinity,   # ledgers this node may work at once
  max_concurrent_acquisitions: 4,   # lease acquisitions in flight on this node
  coordination_strategy: :database_polling,  # the only value in this release
  processor_name: "command_queue"   # prefix of the generated owner id
```

In this "BYO-repo" mode the library does not start its own repo. The command
queue needs the consumer's repo to be running, so add
`DoubleEntryLedger.children/0` to your supervision tree **after** your repo.

Set a strong `idempotency_secret` — it hashes incoming keys. Set
`start_command_queue: false` to disable background processing (useful in
tests or when embedding the ledger without the queue). `retry_interval` is read
at runtime; `max_retries` is captured into each OCC worker at compile time
(`Occ.Processor.__using__/1`), so changing it needs a recompile. Inside the
`:command_queue` list only `max_retries`, `base_retry_delay` and
`max_retry_delay` are read with `Application.compile_env/3`; the other keys are
read at runtime through `CommandQueue.Config`, which also validates the keys
it owns. `CommandQueue.Config.validate!/0` runs both when the queue supervisor
starts and in every `InstanceProcessor.init/1` — the second because the
supervisor does not run at all when `start_command_queue: false`, which is
exactly the setup that starts a processor by hand. It raises naming the first
bad key; `processor_name` and the three compile-time retry keys are not among
the keys it checks. The supervisor then calls
`CommandQueue.Config.warn_stale_config/0`, which logs — never raises — about
configuration this release stopped reading: a key in the `:command_queue` list
that nothing reads, and `batch_enabled` or `batch_size` still set at the top
level, where 0.5 read them and 0.6 does not.

`insert_path: :legacy` and `batch_enabled: false` are the conservative
defaults. To opt into the new paths, set `insert_path: :insert_all` and/or
`batch_enabled: true` in the consuming application's configuration. Set
`batch_size` to control how many compatible transaction commands are processed
together and `max_batch_retries` to control retries after a stale account
write. Account commands continue through the single-command path.
`batch_enabled`, `batch_size` and `pending_fetch_limit` all live in the
`:command_queue` list. `pending_fetch_limit` controls how many queue IDs an
instance processor fetches per database read; it is independent of
`batch_size`. When batching is enabled,
set it to at least `batch_size` and preferably to a multiple of `batch_size` so
each database fetch can be divided into full batches.

`serialize_enqueue: true` makes `CommandStore.create/1` take a
transaction-scoped PostgreSQL advisory lock keyed on the ledger before the
queue item allocates its position. Queue positions are assigned from a
sequence, so without the lock two concurrent enqueues for one ledger can
commit in the opposite order to their positions and the processor may see the
later position first. With the lock, positions for one ledger are allocated in
commit order. Ledgers are locked independently except for a possible 32-bit
hash collision, which only adds waiting. The cost is that concurrent enqueues
for the same ledger become serial, and if you wrap `create/1` in your own
transaction the lock is held until that outer transaction ends. It is read at
runtime and off by default. The setting is node-local, so every node that
enqueues commands must enable it for the ordering guarantee to hold.
Dependency configuration files are not loaded by a host application, so the
`INSERT_PATH`, `BATCH`, and `BATCH_SIZE` environment-variable helpers in this
repository's `config/runtime.exs` only apply when running this repository
directly. A consuming release must translate any environment variables into
`:double_entry_ledger` configuration in its own `config/runtime.exs`.

**Ownership.** Each ledger (instance) has a lease row in PostgreSQL
(`command_queue_leases`). A node's `InstanceMonitor` acquires the lease before
it starts a processor; the processor renews it from an idle heartbeat and
through every claim, processing and batch transaction, and releases it when the
ledger drains or the node shuts down. Every write the queue makes to claim,
complete, retry or dead-letter a queued command takes the lease row lock first,
proves its `(owner_id, fencing_token)` still holds the ledger, and refreshes
the expiry last, so a processor that has lost the ledger cannot overwrite its
successor's work. The lease covers queued commands only: synchronous
processing through `CommandApi.process_from_params/2` takes no lease, runs on
whichever node calls it, and is serialised against the ledger's queue owner
only by account-level optimistic concurrency control. If a node dies, its leases expire after `lease_ttl` and another node takes
them over on its next poll, rescheduling any command the dead node left
`:processing`. Typical detection time is `lease_ttl + poll_interval` (25 s with
the defaults); completing the takeover also depends on pool checkout and how
many in-flight commands must be rescheduled, so treat that as typical, not
guaranteed. `max_leases_per_node` caps how many ledgers one node works at once
and `max_concurrent_acquisitions` caps acquisition tasks per node; both count
supervised processors and acquisitions only. Manual processing via
`CommandWorker.process_command_with_id/2` with a string prefix takes a short
lease of its own outside those caps, and must be called outside a transaction.
Telemetry from different processes may arrive out of order; correlate lease
events by `owner_id` and `fencing_token`.

**Standalone mode** (omit `:repo`): the library ships its own
`DoubleEntryLedger.Repo` and supervises it automatically. Configure it
as a normal Ecto repo per env:

```elixir
config :double_entry_ledger, ecto_repos: [DoubleEntryLedger.Repo]

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10
```

This is useful for running DEL on its own (tests, demos), but for
production apps prefer the BYO-repo form above.

### 3. Run the migrations

#### Fresh install (recommended)

```bash
mix double_entry_ledger.install
mix ecto.migrate
```

This generates a migration file for the core ledger tables.

#### Upgrading from v0.1.0

If you previously copied migration files from v0.1.0, generate an upgrade
migration instead:

```bash
mix double_entry_ledger.install --from 1
mix ecto.migrate
```

This applies schema versions 2–6, including the FK fixes,
`negative_limit`, trace context, query indexes, direct journal-event foreign
keys, queue instance IDs, widened balance columns, and the
`command_queue_leases` table. Version 6 is one-way: `Migration.down/1` refuses
to cross it, so take a database backup first.

**Historical background-job migration:** v0.1.0 included a migration for the
then-used job runner. An already-applied migration and its tables may remain;
0.6.0 does not drop them because the host application may use that job runner
independently. If you still need to execute or roll back that migration,
declare the original dependency in your application rather than relying on DEL
to provide it.

#### Manual migration

Create a migration and call the migration module directly:

```elixir
defmodule MyApp.Repo.Migrations.SetupDoubleEntryLedger do
  use Ecto.Migration

  def up, do: DoubleEntryLedger.Migration.up()
  def down, do: DoubleEntryLedger.Migration.down()
end
```

See `DoubleEntryLedger.Migration` docs for all options (`:version`, `:from`,
`:prefix`). `down/1` raises rather than rolling back past version 6.

### 4. Add the command queue to your supervision tree

In BYO-repo mode, add `DoubleEntryLedger.children/0` to your supervision tree
so DEL's command queue starts after your repo:

```elixir
# lib/my_app/application.ex
children =
  [
    MyApp.Repo,
    # …other children…
  ] ++ DoubleEntryLedger.children()
```

In standalone mode the library supervises the command queue itself and
consumers do not need to call `DoubleEntryLedger.children/0`.

## Quickstart

### Create a ledger instance and accounts

```elixir
alias DoubleEntryLedger.Stores.{InstanceStore, AccountStore}

{:ok, instance} =
  InstanceStore.create(%{
    address: "Acme:Ledger",
    description: "Internal ledger for ACME Corp"
  })

{:ok, cash} =
  AccountStore.create(instance.address, %{
    address: "cash:operating",
    type: :asset,
    currency: :USD,
    name: "Operating Cash",
    negative_limit: 0             # default; rejects any negative available balance
  })

{:ok, equity} =
  AccountStore.create(instance.address, %{
    address: "equity:capital",
    type: :equity,
    currency: :USD,
    name: "Owners' Equity",
    negative_limit: 1_000_00      # allow available to go as low as -1_000_00
  })
```

### Process a transaction synchronously

```elixir
alias DoubleEntryLedger.Apis.CommandApi

command = %{
  "instance_address" => instance.address,
  "action" => "create_transaction",
  "source" => "back-office",
  "source_idempk" => "initial-capital-1",
  "payload" => %{
    status: :posted,
    entries: [
      %{"account_address" => cash.address, "amount" => 1_000_00, "currency" => :USD},
      %{"account_address" => equity.address, "amount" => 1_000_00, "currency" => :USD}
    ]
  }
}

{:ok, transaction, processed_command} = CommandApi.process_from_params(command)
```

Provide positive amounts to add value and negative amounts to subtract it—the ledger will derive the correct debit or credit per account type and reject unbalanced transactions.

### Queue a command for asynchronous processing

```elixir
async_command = Map.put(command, "source_idempk", "initial-capital-async")
{:ok, queued_command} = CommandApi.create_from_params(async_command)
# InstanceMonitor will claim it, process it, and update the command_queue_item status.
```

Inspect queued work with `DoubleEntryLedger.Stores.CommandStore.list_for_instance/2` or check `command.command_queue_item.status`.

### Reserve funds with pending transactions

```elixir
hold_event = %{
  "instance_address" => instance.address,
  "action" => "create_transaction",
  "source" => "checkout",
  "source_idempk" => "order-123",
  "payload" => %{
    status: :pending,
    entries: [
      %{"account_address" => cash.address, "amount" => -200_00, "currency" => :USD},
      %{"account_address" => equity.address, "amount" => -200_00, "currency" => :USD}
    ]
  }
}

{:ok, pending_tx, _command} = CommandApi.process_from_params(hold_event)

# Later, finalize the hold
CommandApi.process_from_params(%{
  "instance_address" => instance.address,
  "action" => "update_transaction",
  "source" => "checkout",
  "source_idempk" => "order-123",
  "update_idempk" => "order-123-post",
  "payload" => %{status: :posted}
})
```

`source` + `source_idempk` uniquely identify the original event, and `update_idempk` must be unique per update. Only pending transactions can be updated.

### Query ledger state

```elixir
alias DoubleEntryLedger.Instance
alias DoubleEntryLedger.Stores.{AccountStore, TransactionStore, JournalEventStore, CommandStore}

AccountStore.get_by_id(cash.id).available

{:ok, {history, _meta}} = AccountStore.list_balance_history(cash.id)
{:ok, {transactions, _meta}} = TransactionStore.list_for_instance(instance.id)
{:ok, {events, _meta}} = JournalEventStore.list_for_account(cash.id)

CommandStore.get_by_id(command.id)
```

Each list function accepts an optional second-argument map of
[Flop](https://hex.pm/packages/flop) params (cursor, filters, ordering) —
see the store moduledocs for the allow-listed filter fields.

Use `Instance.validate_account_balances(instance)` to assert the ledger
still balances, or `PendingTransactionLookup` to inspect open holds.

## Background Processing

- `DoubleEntryLedger.CommandQueue.InstanceMonitor` polls for ledgers that have processable commands and no live lease, acquires the lease for each one in its own task, and starts an `InstanceProcessor` with the resulting grant. Which ledgers this node attempts is decided by a `CommandQueue.Coordinator`; only the PostgreSQL lease grants ownership.
- `InstanceProcessor` claims work through an atomic scheduling claim — `CommandQueue.Scheduling.claim_command_for_processing/3` for a single command, `claim_batch_for_processing/3` in batch mode — runs the appropriate worker, and marks the `CommandQueueItem` as `:processed`. Each worker task is monitored via `Process.monitor/1`; if the task crashes, the processor schedules a retry automatically.
- OCC is handled inside the workers (see `lib/double_entry_ledger/occ`). Retries use exponential backoff until `max_retries` is reached, after which commands are marked as `:dead_letter`.
- Errors and retry metadata live on the `command_queue_item`, so you can inspect processing attempts via `CommandStore` or SQL views.
- Journal-event relationships are persisted synchronously through direct foreign keys; the command path no longer enqueues an internal linking job.
- Commands left in `:processing` by a node that died are rescheduled by the next lease acquisition on that ledger and sent back through the normal retry or dead-letter path; each one emits `[:double_entry_ledger, :command, :recovered]` with `reason: :takeover`. Discovery includes ledgers whose only rows are `:processing` under an expired lease, so that happens without new work arriving. A successful enqueue also wakes the monitor when the queue is supervised locally, so an idle queue starts draining immediately instead of waiting a full `poll_interval`; otherwise the command waits for the next poll on a node that runs the queue.

### Running on several nodes

A ledger's queued commands are worked by one node at a time, and PostgreSQL
decides which.
`CommandQueue.Lease` holds one row per ledger with an owner id, a
monotonically increasing fencing token, and a database-clock expiry. A monitor
acquires that row before it starts a processor, the processor holds it for its
whole lifetime, and every write that claims, completes, retries or
dead-letters a queued command takes the row lock, proves its
`(owner_id, fencing_token)` still holds the ledger, and refreshes the expiry
last. A processor whose ledger has moved on sees a zero-row owner update,
emits `[:lease, :lost]`, and stops without writing. Commands stranded in
`:processing` by a node that died are rescheduled by the next owner's
acquisition. Those guarantees hold under concurrency across any number of
nodes, and are what make a crash, a restart, or a rolling deploy between 0.6
nodes safe. They do not extend to synchronous processing; see the first open
item below.

Two nodes discovering the same unleased ledger in the same window is expected
rather than a fault: the loser gets `:held` or `:busy` from `Lease.acquire/4`
and moves on. Two owners that can both write for one ledger, concurrent
claims of one ledger's commands from different nodes, and a stale owner
overwriting its successor's work are all prevented by the lease, not by the
node-local `CommandQueue.Registry` — the Registry is process naming and one
node's own exclusion, and it is a correct but no longer load-bearing part of
the story. The lease does not guarantee a single `InstanceProcessor` process:
a monitor slow enough to start a processor on a grant that has already expired
leaves it coexisting with the new owner until its first fenced claim or
renewal fails, at which point it emits `[:lease, :lost]` and stops without
writing.

What is still open across several nodes:

- **Synchronous processing takes no lease.** `CommandApi.process_from_params/2`
  processes the command on the calling node, under no lease, whichever node
  currently owns the ledger's queue. Its writes are serialised against the
  queue owner's only by account-level optimistic concurrency control
  (`Account.lock_version`), the same mechanism that serialises two
  synchronous callers.
- **Runtime configuration is per node.** `batch_enabled`, `batch_size`,
  `pending_fetch_limit`, `poll_interval`, `lease_ttl`, `lease_lock_timeout_ms`,
  `max_leases_per_node`, `max_concurrent_acquisitions`, `processor_name` and
  the top-level `serialize_enqueue` are read from each node's own application
  environment. Correctness does not depend on them agreeing — the lease fences
  the writes either way — but behaviour does. Failover timing is
  `lease_ttl + poll_interval`: a node with a shorter `lease_ttl` gives its
  ledgers up sooner than the others after it dies, and a node with a longer
  `poll_interval` picks orphaned ledgers up later, so failover is uneven; mismatched batching makes the same queue drain
  differently depending on which node picked it up; and `serialize_enqueue`
  only delivers commit-order queue positions if every node that enqueues sets
  it. Deploy the `:command_queue` list consistently.
- **Discovery is polling, with no cross-node notification.** Each node runs
  its own `InstanceMonitor` and its own discovery SELECT. `InstanceMonitor.wake/1`
  after an enqueue reaches the local monitor only; a command enqueued on one
  node still reaches another node's monitor through that node's next poll.
  Nothing tells the cluster that a node has gone; its ledgers are picked up
  when the lease expires and some node's poll comes round. Typical failover is
  therefore `lease_ttl + poll_interval` — 25 s with the defaults — and slower
  if pool checkout or a large set of orphaned rows delays the takeover
  transaction. There is no `LISTEN`/`NOTIFY` or cluster-aware signal.
- **`:database_polling` is the only coordination strategy.** The
  `CommandQueue.Coordinator` behaviour is the seam for an `:erlang_cluster`
  strategy that would partition discovery instead of having every node poll;
  it is not implemented, and `CommandQueue.Config.validate!/0` rejects any
  other value.

Two-node failover timing is not covered by the automated suite; the lease
mechanics it depends on are, single-node.

## Documentation & Further Reading

- [Ledger internals & synchronous walkthrough](pages/DoubleEntryLedger.md)
- [Asynchronous processing details](pages/AsynchronousEventProcessing.md)
- [Handling pending transactions and available balances](pages/HandlingPendingTransactions.md)
- [Event sourcing architecture notes](pages/EventSourcing.md)
- [Telemetry events and metrics](pages/Telemetry.md)

Generate fresh API docs locally with:

```bash
mix docs
```

Extras are bundled in `pages/` when you run `mix docs`.

## Development

- `mix deps.get` – install dependencies.
- `mix ecto.create && mix ecto.migrate` – prepare the database.
- `mix test` – run the test suite (aliases automatically create/migrate the test DB).
- `mix credo --strict` and `mix dialyzer` – static analysis.
- `mix docs` – regenerate documentation, or `mix tidewave` to preview docs via the built-in dev server.

## Migrating from 0.5.x to 0.6.0

> ⚠️ **0.6.0 contains a breaking schema change and requires a drained
> deployment.** There is no supported mixed-version window, and migration 6
> cannot be rolled back.

Migration 6 adds `command_queue_leases` and drops
`command_queue_items.processor_version`. 0.5 writes `processor_version` on
every queue update and names it in every enqueue INSERT, so a 0.5 node of any
kind — processor or enqueuer — fails against the 0.6 schema.

1. Stop **every** 0.5 node, enqueuers included.
2. Take a database backup. Migration 6 is one-way; restoring that backup is
   the only route back to 0.5.
3. Apply the migration:

   ```bash
   mix double_entry_ledger.install --from 5
   mix ecto.migrate
   ```

   Or call `DoubleEntryLedger.Migration.up(from: 5)` from your own migration.
4. Start the 0.6.0 nodes. Rows left `:processing` by 0.5 are rescheduled by
   the first 0.6 lease acquisition on each ledger.

Configuration changes:

- Remove `:stale_processing_after` from the `:command_queue` list. The
  recovery sweep it configured is gone and the key is no longer read. Leaving
  it in place changes nothing, but the queue supervisor logs a warning naming
  it at start-up — as it does for any `:command_queue` key the library does
  not read, and for `batch_enabled` or `batch_size` left at the top level.
- Optionally set the new `:command_queue` keys `lease_ttl`,
  `lease_lock_timeout_ms`, `max_leases_per_node`,
  `max_concurrent_acquisitions` and `coordination_strategy`. All have working
  defaults; see [Configuration](#2-configure-the-application) and "Ownership".

API changes to check for:

- `CommandQueue.Scheduling.claim_command_for_processing/3` and
  `claim_batch_for_processing/3` take a `CommandQueue.Lease.Grant`, not a
  `processor_id` string.
- `InstanceProcessor.start_link/1` requires a `:grant`. Acquire one with
  `CommandQueue.Lease.acquire/4` if you start a processor by hand.
- `CommandWorker.process_command_with_id/2` still accepts a string, but that
  now means "take a lease of your own": call it outside any transaction, and
  handle `{:error, :ledger_owned}`, `{:error, :ledger_busy}` and
  `{:error, :in_transaction}`. Processing can additionally return
  `{:error, :lease_lost}` and `{:error, :lease_busy}`.
- `{:error, :command_ownership_lost}`, `{:error, :command_already_claimed}` and
  `CommandQueue.OwnershipError` are gone.
- `[:double_entry_ledger, :command, :recovered]` no longer carries
  `stale_for_seconds`; it carries `reason: :takeover` and is emitted only when
  a lease acquisition reschedules an orphan. Four
  `[:double_entry_ledger, :lease, …]` events are new — see
  [Telemetry](pages/Telemetry.md).

See [CHANGELOG.md](CHANGELOG.md) for the full list.

## Migrating from 0.4.x to 0.5.0

> ⚠️ **0.5.0 contains breaking schema and API changes.** Migration 5 is not
> compatible with a mixed 0.4.x/0.5.0 rolling deployment. Stop 0.4.x
> command processing, apply the upgrade migration, deploy 0.5.0, and then
> resume processing.

Generate and run an upgrade migration from schema version 4:

```bash
mix double_entry_ledger.install --from 4
mix ecto.migrate
```

The migration performs these changes:

1. Replaces `journal_event_*_links` tables with direct `command_id`,
   `transaction_id`, and `account_id` columns on `journal_events`. Update custom
   queries and preloads to use the direct associations.
2. Adds and backfills `command_queue_items.instance_id`, then makes it required.
   Custom code building queue-item changesets must provide `instance_id`.
3. Widens account and balance-history integer balance/limit columns to `bigint`.
   A later downgrade can fail if stored values exceed the old integer range.
4. Moves `commands.inserted_at` plus command-queue insertion, update,
   processing-start, and processing-completion timestamp generation to
   PostgreSQL so processing times do not depend on application-node clocks.
5. Adds and backfills `command_queue_items.queue_position` from a PostgreSQL
   sequence, then uses it as the stable queue-processing order. Existing rows
   receive dense positions in `(inserted_at, command_id)` order; PostgreSQL uses
   the sequence for rows inserted after the backfill.
6. Adds the transient `command_queue_items.retry_delay_seconds` column and the
   queue-trigger rule that turns it into `next_retry_after` on the PostgreSQL
   clock, so retry timing no longer depends on application-node clocks.

The queue-position backfill rewrites every `command_queue_items` row, including
processed and dead-letter history, while holding an `ACCESS EXCLUSIVE` table
lock. Its runtime
therefore scales with total queue history, not only currently processable work.
Plan an appropriate maintenance window before applying it to a large table.

`Command.processing_start_changeset/3` and
`CommandQueueItem.processing_start_changeset/3` were removed; callers must claim
through `CommandQueue.Scheduling.claim_command_for_processing/3`, which enforces
queue status and the retry deadline in one atomic UPDATE.

The `JournalEventAccountLink`, `JournalEventCommandLink`,
`JournalEventTransactionLink`, and legacy journal-event link worker have been
removed. DEL no longer depends on or supervises a third-party job runner, and
journal-event relationships are now written synchronously. Remove the obsolete
DEL job-runner configuration; applications using a job runner for their own
work must declare, migrate, configure, and supervise it independently. Existing
job-runner tables are intentionally left untouched.

Batching remains opt-in. Configure `insert_path`, `batch_enabled`, and
`batch_size` in the consuming application; this dependency's
`config/runtime.exs` is not loaded by the host release.

## Migrating from 0.3.x to 0.4.0

> ⚠️ **0.4.0 contains breaking changes.** Read this whole section before
> bumping the dependency — at minimum you'll update store call sites and
> supervision. See [CHANGELOG.md](CHANGELOG.md) for the canonical migration
> notes per item.

### Breaking changes at a glance

1. **Store list functions renamed and re-shaped.** `list_all_*` and
   `get_all_accounts_*` are gone; replacements are `list_for_*` under
   Flop. Returns are now `{:ok, {[item], %Flop.Meta{}}}`. Update every
   call site — see the [Function rename map](#function-rename-map) and
   the Before/After example below.

2. **Pagination is cursor-based** via [Flop](https://hex.pm/packages/flop).
   `(id, page, per_page)` → `(id, flop_params_map)`. No consumer
   `config :flop, repo: …` required — DEL ships its own backend.

3. **Supervision shift in BYO-repo mode.** If you opt into BYO-repo
   via `config :double_entry_ledger, repo: MyApp.Repo`, DEL no longer
   supervises the command queue from its own tree. Add
   `DoubleEntryLedger.children/0` to your app's supervisor. Standalone
   consumers (no `:repo` set) are unaffected.

### New: bring your own repo

0.4.0 adds `config :double_entry_ledger, repo: MyApp.Repo` so the library
shares the host's connection pool (and one Ecto sandbox in tests)
instead of shipping its own `DoubleEntryLedger.Repo`. When `:repo` is
omitted, the library runs in standalone mode as before. See
[Configuration](#2-configure-the-application) for the full setup.

### Before (0.3.x)

```elixir
transactions = TransactionStore.list_all_for_instance_id(instance.id, 1, 40)
```

### After (0.4.x)

```elixir
{:ok, {transactions, meta}} = TransactionStore.list_for_instance(instance)

# Next page — cursor pagination
{:ok, {next, _meta}} =
  TransactionStore.list_for_instance(instance, %{first: 40, after: meta.end_cursor})

# With a filter (allow-listed field)
{:ok, {pending, _meta}} =
  TransactionStore.list_for_instance(instance, %{
    filters: [%{field: :status, op: :==, value: :pending}]
  })
```

### Function rename map

| 0.3.x | 0.4.0 |
|---|---|
| `InstanceStore.list_all/0` | `InstanceStore.list/1` |
| `AccountStore.get_all_accounts_by_instance_id/1` | `AccountStore.list_for_instance/2` |
| `AccountStore.get_all_accounts_by_instance_address/1` | `AccountStore.list_for_instance_address/2` |
| `AccountStore.get_accounts_by_instance_id_and_type/2` | `AccountStore.list_for_instance/2` with `filters: [%{field: :type, op: :==, value: type}]` |
| `AccountStore.get_balance_history_by_id/3` | `AccountStore.list_balance_history/2` |
| `AccountStore.get_balance_history_by_address/4` | `AccountStore.list_balance_history_by_address/3` |
| `AccountStore.get_balance_history_by_account/3` | `AccountStore.list_balance_history/2` |
| `TransactionStore.list_all_for_instance_id/3` | `TransactionStore.list_for_instance/2` |
| `TransactionStore.list_all_for_instance_address/3` | `TransactionStore.list_for_instance_address/2` |
| `TransactionStore.list_all_for_instance_id_and_account_id/4` | `TransactionStore.list_for_instance_and_account/3` |
| `TransactionStore.list_all_for_instance_address_and_account_address/4` | `TransactionStore.list_for_instance_and_account_address/3` |
| `CommandStore.list_all_for_instance_id/3` | `CommandStore.list_for_instance/2` |
| `CommandStore.list_all_for_transaction_id/1` | `CommandStore.list_for_transaction/2` |
| `JournalEventStore.list_all_for_instance_id/3` | `JournalEventStore.list_for_instance/2` |
| `JournalEventStore.list_all_for_account_id/3` | `JournalEventStore.list_for_account/2` |
| `JournalEventStore.list_all_for_account_address/2` | `JournalEventStore.list_for_account_address/3` |
| `JournalEventStore.list_all_for_transaction_id/1` | `JournalEventStore.list_for_transaction/2` |

All `list_for_*` functions that take a parent scope accept either the parent struct (`Instance.t()`, `Account.t()`, `Transaction.t()`) **or** its UUID string.

## License

DoubleEntryLedger is released under the [MIT License](LICENSE).
