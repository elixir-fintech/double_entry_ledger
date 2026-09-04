# DoubleEntryLedger

**[![Elixir CI](https://github.com/elixir-fintech/double_entry_ledger/actions/workflows/elixir.yml/badge.svg)](https://github.com/elixir-fintech/double_entry_ledger/actions/workflows/elixir.yml)**

DoubleEntryLedger is an event sourced, multi-tenant double entry accounting engine for Elixir and PostgreSQL. It provides typed accounts, signed amount APIs, pending/posting flows, an optimistic-concurrency command queue, and a fully auditable journal so you can embed reliable ledgering without rebuilding the fundamentals.

## Highlights

- Multi tenant ledger instances with typed accounts (asset/liability/equity/revenue/expense) and [Money](https://hexdocs.pm/money) backed multi currency support.
- Signed amount API converts intent into the correct debit or credit entry and enforces balanced transactions per currency.
- Immutable `Command`, `JournalEvent`, and `BalanceHistoryEntry` records plus idempotency keys give a complete audit trail.
- Background command queue with OCC, exponential retries, per-instance processors, and idempotency controls makes command processing safe to retry.
- Pending vs. posted projections with automatic `available` balances support holds, authorizations, and delayed settlements.
- Rich stores and APIs (`InstanceStore`, `AccountStore`, `TransactionStore`, `CommandStore`, `CommandApi`, `JournalEventStore`) keep ledger interactions safe and consistent.
- Everything lives inside the configurable `double_entry_ledger` schema so it coexists peacefully with your application tables.

## System Overview

### Instances & Accounts

`DoubleEntryLedger.Stores.InstanceStore` (`lib/double_entry_ledger/stores/instance_store.ex`) defines isolation boundaries. Each instance owns its own configuration, accounts, and transactions. `DoubleEntryLedger.Stores.AccountStore` validates account type, currency, addressing format, and maintains embedded `posted`, `pending`, and `available` balance structs. Helpers in `DoubleEntryLedger.Types` and `DoubleEntryLedger.Utils.Currency` encapsulate allowed values.

### Commands, Journal Events & Transactions

External requests enter through `DoubleEntryLedger.Apis.CommandApi` (`lib/double_entry_ledger/apis/command_api.ex`). Requests are normalized into `TransactionCommandMap` or `AccountCommandMap` structs, hashed for idempotency, and saved as immutable `Command` records (`lib/double_entry_ledger/schemas/command.ex`). Successful processing creates `JournalEvent` records plus `Transaction` + `Entry` rows. Each journal event stores direct foreign keys to its command and related transaction or account. Query stores such as `DoubleEntryLedger.Stores.TransactionStore` and `DoubleEntryLedger.Stores.JournalEventStore` expose read models by instance, account, or transaction.

### Queues, Workers & OCC

The command queue (`lib/double_entry_ledger/command_queue`) polls for pending commands via `InstanceMonitor`, spins up `InstanceProcessor` processes per instance, and uses `CommandQueue.Scheduling` to claim, retry, or dead-letter work. The transaction-related workers under `lib/double_entry_ledger/workers/command_worker` implement `DoubleEntryLedger.Occ.Processor`, translating event maps into `Ecto.Multi` workflows that retry on `Ecto.StaleEntryError`. Journal-event relationships are written synchronously with the journal event; there is no internal linking job in 0.5.0.

### Balances & Audit Trails

Each transaction updates `Account` projections plus immutable `BalanceHistoryEntry` snapshots, enabling temporal queries and reconciliation. Instances can be validated with `InstanceStore.validate_account_balances/1`, ensuring posted and pending debits/credits remain equal. Direct `command_id`, `transaction_id`, and `account_id` foreign keys on journal events provide traceability from the original request to the final projection.

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
    {:double_entry_ledger, "~> 0.5.0"}
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
  batch_enabled: false,
  batch_size: 8,
  max_batch_retries: 3,
  max_retries: 5,
  retry_interval: 200

config :double_entry_ledger, :command_queue,
  poll_interval: 5_000,
  pending_fetch_limit: 64,
  max_retries: 5,
  base_retry_delay: 30,
  max_retry_delay: 3_600,
  processor_name: "command_queue"
```

In this "BYO-repo" mode the library does not start its own repo. The command
queue needs the consumer's repo to be running, so add
`DoubleEntryLedger.children/0` to your supervision tree **after** your repo.

Set a strong `idempotency_secret` — it hashes incoming keys. Set
`start_command_queue: false` to disable background processing (useful in
tests or when embedding the ledger without the queue). `max_retries` and
`retry_interval` are read at runtime, so they can be changed without
recompilation.

`insert_path: :legacy` and `batch_enabled: false` are the conservative
defaults. To opt into the new paths, set `insert_path: :insert_all` and/or
`batch_enabled: true` in the consuming application's configuration. Set
`batch_size` to control how many compatible transaction commands are processed
together and `max_batch_retries` to control retries after a stale account
write. Account commands continue through the single-command path.
`pending_fetch_limit` controls how many queue IDs an instance processor fetches
per database read; it is independent of `batch_size`. When batching is enabled,
set it to at least `batch_size` and preferably to a multiple of `batch_size` so
each database fetch can be divided into full batches.
Dependency configuration files are not loaded by a host application, so the
`INSERT_PATH`, `BATCH`, and `BATCH_SIZE` environment-variable helpers in this
repository's `config/runtime.exs` only apply when running this repository
directly. A consuming release must translate any environment variables into
`:double_entry_ledger` configuration in its own `config/runtime.exs`.

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

This applies schema versions 2–7, including the FK fixes,
`negative_limit`, trace context, query indexes, direct journal-event foreign
keys, queue instance IDs, and widened balance columns.

**Historical background-job migration:** v0.1.0 included a migration for the
then-used job runner. An already-applied migration and its tables may remain;
0.5.0 does not drop them because the host application may use that job runner
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
`:prefix`).

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

- `DoubleEntryLedger.CommandQueue.InstanceMonitor` polls for commands in `:pending`, `:occ_timeout`, or `:failed` status and ensures each instance has an `InstanceProcessor`.
- `InstanceProcessor` claims work via `CommandQueue.Scheduling.claim_command_for_processing/2`, runs the appropriate worker, and marks the `CommandQueueItem` as `:processed`. Each worker task is monitored via `Process.monitor/1`; if the task crashes, the processor schedules a retry automatically.
- OCC is handled inside the workers (see `lib/double_entry_ledger/occ`). Retries use exponential backoff until `max_retries` is reached, after which commands are marked as `:dead_letter`.
- Errors and retry metadata live on the `command_queue_item`, so you can inspect processing attempts via `CommandStore` or SQL views.
- Journal-event relationships are persisted synchronously through direct foreign keys; the command path no longer enqueues an internal linking job.

## Documentation & Further Reading

- [Ledger internals & synchronous walkthrough](pages/DoubleEntryLedger.md)
- [Asynchronous processing details](pages/AsynchronousEventProcessing.md)
- [Handling pending transactions and available balances](pages/HandlingPendingTransactions.md)
- [Event sourcing architecture notes](pages/EventSourcing.md)

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

## Migrating from 0.4.x to 0.5.0

> ⚠️ **0.5.0 contains breaking schema and API changes.** Migrations 5 and
> 6 are not compatible with a mixed 0.4.x/0.5.0 rolling deployment. Stop 0.4.x
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

Migration v9 rewrites every `command_queue_items` row, including processed and
dead-letter history, while holding an `ACCESS EXCLUSIVE` table lock. Its runtime
therefore scales with total queue history, not only currently processable work.
Plan an appropriate maintenance window before applying it to a large table.

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
