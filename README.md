# DoubleEntryLedger

**[![Elixir CI](https://github.com/csommerauer/double_entry_ledger/actions/workflows/elixir.yml/badge.svg)](https://github.com/csommerauer/double_entry_ledger/actions/workflows/elixir.yml)**

DoubleEntryLedger is an event sourced, multi-tenant double entry accounting engine for Elixir and PostgreSQL. It provides typed accounts, signed amount APIs, pending/posting flows, an optimistic-concurrency command queue, and a fully auditable journal so you can embed reliable ledgering without rebuilding the fundamentals.

## Highlights

- Multi tenant ledger instances with typed accounts (asset/liability/equity/revenue/expense) and [Money](https://hexdocs.pm/money) backed multi currency support.
- Signed amount API converts intent into the correct debit or credit entry and enforces balanced transactions per currency.
- Immutable `Command`, `JournalEvent`, and `BalanceHistoryEntry` records plus idempotency keys give a complete audit trail.
- Background command queue with OCC, exponential retries, per instance processors, and Oban powered linking jobs ensures exactly once processing.
- Pending vs. posted projections with automatic `available` balances support holds, authorizations, and delayed settlements.
- Rich stores and APIs (`InstanceStore`, `AccountStore`, `TransactionStore`, `CommandStore`, `CommandApi`, `JournalEventStore`) keep ledger interactions safe and consistent.
- Everything lives inside the configurable `double_entry_ledger` schema so it coexists peacefully with your application tables.

## System Overview

### Instances & Accounts
`DoubleEntryLedger.Stores.InstanceStore` (`lib/double_entry_ledger/stores/instance_store.ex`) defines isolation boundaries. Each instance owns its own configuration, accounts, and transactions. `DoubleEntryLedger.Stores.AccountStore` validates account type, currency, addressing format, and maintains embedded `posted`, `pending`, and `available` balance structs. Helpers in `DoubleEntryLedger.Types` and `DoubleEntryLedger.Utils.Currency` encapsulate allowed values.

### Commands, Journal Events & Transactions
External requests enter through `DoubleEntryLedger.Apis.CommandApi` (`lib/double_entry_ledger/apis/command_api.ex`). Requests are normalized into `TransactionEventMap` or `AccountCommandMap` structs, hashed for idempotency, and saved as immutable `Command` records (`lib/double_entry_ledger/schemas/command.ex`). Successful processing creates `JournalEvent` records plus `Transaction` + `Entry` rows, and finally typed links (`journal_event_*_links`). Query stores such as `DoubleEntryLedger.Stores.TransactionStore` and `DoubleEntryLedger.Stores.JournalEventStore` expose read models by instance, account, or transaction.

### Queues, Workers & OCC
The command queue (`lib/double_entry_ledger/command_queue`) polls for pending commands via `InstanceMonitor`, spins up `InstanceProcessor` processes per instance, and uses `CommandQueue.Scheduling` to claim, retry, or dead-letter work. The transaction related workers under `lib/double_entry_ledger/workers/command_worker` implement `DoubleEntryLedger.Occ.Processor`, translating event maps into `Ecto.Multi` workflows that retry on `Ecto.StaleEntryError`. When the command finishes, `DoubleEntryLedger.Workers.Oban.JournalEventLinks` runs via Oban to build any missing journal links.

### Balances & Audit Trails
Each transaction updates `Account` projections plus immutable `BalanceHistoryEntry` snapshots, enabling temporal queries and reconciliation. Instances can be validated with `InstanceStore.validate_account_balances/1`, ensuring posted and pending debits/credits remain equal. Journal events plus `JournalEventTransactionLink`/`JournalEventAccountLink` tables provide traceability from the original request to the final projection.

### Idempotency & Isolation
Every command requires a `source` and `source_idempk` (plus `update_idempk` for updates). These keys are hashed via `DoubleEntryLedger.Command.IdempotencyKey` to prevent duplicates, while `PendingTransactionLookup` enforces a single open update chain for each pending transaction. All tables live inside the configurable `schema_prefix` (`double_entry_ledger` by default), so migrations never clash with your application schema.

## Requirements

- Elixir `~> 1.15` and OTP 26.
- PostgreSQL 14+ with permission to create the `double_entry_ledger` schema and the [Oban](https://hexdocs.pm/oban) jobs table.
- Access to run Mix tasks (`mix ecto.create`, `mix ecto.migrate`, `mix test`, etc.).
- Recommended: `money`, `logger_json`, `oban`, `jason`, `credo`, and `dialyxir` (included in `mix.exs`).

## Installation

### 1. Add the dependency

DoubleEntryLedger is not published on Hex yet, so point Mix at the GitHub repository:

```elixir
def deps do
  [
    {:double_entry_ledger, git: "https://github.com/csommerauer/double_entry_ledger.git", branch: "main"}
  ]
end
```

Run `mix deps.get` after updating `mix.exs`.

### 2. Configure the application

```elixir
# config/config.exs
import Config

config :double_entry_ledger,
  ecto_repos: [DoubleEntryLedger.Repo],
  schema_prefix: "double_entry_ledger",
  idempotency_secret: System.fetch_env!("LEDGER_IDEMPOTENCY_SECRET"),
  max_retries: 5,
  retry_interval: 200

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :double_entry_ledger, :event_queue,
  poll_interval: 5_000,
  max_retries: 5,
  base_retry_delay: 30,
  max_retry_delay: 3_600,
  processor_name: "event_queue"

config :double_entry_ledger, Oban,
  repo: DoubleEntryLedger.Repo,
  prefix: "double_entry_ledger",
  engine: Oban.Engines.Basic,
  queues: [double_entry_ledger: 5]
```

Set a strong `idempotency_secret` — it is used to hash incoming keys. Production systems should override the repo credentials, event queue settings, and Oban concurrency.

### 3. Run the migrations

Copy the migrations in `priv/repo/migrations` into your host application (adjust timestamps to keep ordering), create the schema if necessary, and migrate:

```bash
cp -R deps/double_entry_ledger/priv/repo/migrations/*.exs priv/repo/migrations/
mix ecto.create
mix ecto.migrate
```

The migrations create the ledger schema, instances, accounts, transactions, entries, commands, command queue items, pending transaction lookup, journal events and links, idempotency keys, and Oban jobs.

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
    name: "Operating Cash"
  })

{:ok, equity} =
  AccountStore.create(instance.address, %{
    address: "equity:capital",
    type: :equity,
    currency: :USD,
    name: "Owners' Equity"
  })
```

### Process a transaction synchronously

```elixir
alias DoubleEntryLedger.Apis.CommandApi

event = %{
  "instance_address" => instance.address,
  "action" => "create_transaction",
  "source" => "backoffice",
  "source_idempk" => "initial-capital-1",
  "payload" => %{
    status: :posted,
    entries: [
      %{"account_address" => cash.address, "amount" => 1_000_00, "currency" => :USD},
      %{"account_address" => equity.address, "amount" => 1_000_00, "currency" => :USD}
    ]
  }
}

{:ok, transaction, command} = CommandApi.process_from_params(event)
```

Provide positive amounts to add value and negative amounts to subtract it—the ledger will derive the correct debit or credit per account type and reject unbalanced transactions.

### Queue an event for asynchronous processing

```elixir
async_event = Map.put(event, "source_idempk", "initial-capital-async")
{:ok, queued_command} = CommandApi.create_from_params(async_event)
# InstanceMonitor will claim it, process it, and update the command_queue_item status.
```

Inspect queued work with `DoubleEntryLedger.Stores.CommandStore.list_all_for_instance/2` or check `command.command_queue_item.status`.

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
alias DoubleEntryLedger.Stores.{AccountStore, TransactionStore, JournalEventStore, CommandStore}

AccountStore.get_by_id(cash.id).available
AccountStore.get_balance_history(cash.id)
TransactionStore.list_all_for_instance(instance.id)
JournalEventStore.list_all_for_account_id(cash.id)
CommandStore.get_by_id(command.id)
```

Use `InstanceStore.validate_account_balances(instance.address)` to assert the ledger still balances, or `PendingTransactionLookup` to inspect open holds.

## Background Processing

- `DoubleEntryLedger.CommandQueue.InstanceMonitor` polls for commands in `:pending`, `:occ_timeout`, or `:failed` status and ensures each instance has an `InstanceProcessor`.
- `InstanceProcessor` claims work via `CommandQueue.Scheduling.claim_event_for_processing/2`, runs the appropriate worker, and marks the `CommandQueueItem` as `:processed`.
- OCC is handled inside the workers (see `lib/double_entry_ledger/occ`). Retries are scheduled with exponential backoff until `max_retries` is reached, after which commands are marked as `:dead_letter`.
- Errors and retry metadata live on the `command_queue_item`, so you can inspect processing attempts via `CommandStore` or SQL views.
- Oban handles fan-out tasks (currently the journal-event linking job) via `DoubleEntryLedger.Workers.Oban.JournalEventLinks`. Configure the queue size to match your workload.

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

## License

DoubleEntryLedger is released under the [MIT License](LICENSE).
