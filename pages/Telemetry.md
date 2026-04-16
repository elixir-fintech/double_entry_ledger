# Telemetry

DoubleEntryLedger emits `:telemetry` events for command processing, OCC retries,
entity lifecycle changes, and queue infrastructure. The library only emits —
consumers attach their own handlers at application boot and decide where to
ship the data (Prometheus, StatsD, DataDog, Phoenix LiveDashboard, etc.).

All events use the `[:double_entry_ledger, ...]` prefix. All event metadata
uses `instance_id` (UUID) rather than `instance_address` to avoid database
lookups on hot paths.

## Event Catalog

### Span Events

Span events use `:telemetry.span/3` which emits three events sharing a prefix:
`:start`, `:stop`, and `:exception`. Measurements include `duration` on stop
and exception events.

**`[:double_entry_ledger, :command, :process]`**

Wraps the command processing lifecycle in `CommandWorker`.

| Metadata | Description |
|---|---|
| `action` | Command action atom |
| `instance_id` | Ledger instance UUID (nil on the synchronous path before instance resolution) |
| `source` | Source system identifier |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

### Point Events

Point events use `:telemetry.execute/3` with `%{system_time: ...}` measurements.

#### Command Lifecycle

**`[:double_entry_ledger, :command, :enqueue]`** — emitted from `CommandStore.create/1` after a command is persisted to the queue.

| Metadata | Description |
|---|---|
| `action` | Command action atom |
| `instance_id` | Ledger instance UUID |
| `source` | Source system identifier |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :claim]`** — emitted from `Scheduling.claim_command_for_processing/2` after a processor atomically claims a command.

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `processor_id` | Processor identifier string |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :retry]`** — emitted from `Scheduling.build_schedule_retry_with_reason/3` when a command is scheduled for retry (not when it dead-letters).

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `status` | Status being set (`:failed`, `:occ_timeout`) |
| `retry_count` | Current retry count |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :dead_letter]`** — emitted from `Scheduling.build_mark_as_dead_letter/2` when a command is permanently failed.

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `error` | Reason for dead-lettering |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :idempotency_hit]`** — emitted from `TransactionCommandMapResponseHandler` when a duplicate command is detected via idempotency key.

| Metadata | Description |
|---|---|
| `action` | Command action atom |
| `instance_id` | Nil (instance not resolved at violation time) |
| `source` | Source system identifier |
| `source_idempk` | Idempotency key that was duplicated |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

#### OCC

**`[:double_entry_ledger, :occ, :retry]`** — emitted from the OCC processor on each retry attempt (`Ecto.StaleEntryError` caught).

| Metadata | Description |
|---|---|
| `module` | Processor module handling the command |
| `attempts_remaining` | Retry attempts left |
| `command_id` | Command UUID (nil on the synchronous path) |
| `instance_id` | Ledger instance UUID (nil on the synchronous path) |
| `action` | Command action atom |
| `source` | Source system identifier |
| `source_idempk` | Source idempotency key |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

#### Transaction Lifecycle

Emitted from `TransactionCommandResponseHandler` and `TransactionCommandMapResponseHandler` after a successful Multi result. Dispatch uses `Telemetry.emit_transaction/2`:

- `:pending` status → `transaction, :created` event with `status: :pending`
- `:posted` status, `inserted_at == updated_at` → `transaction, :created` with `status: :posted`
- `:posted` status, updated after creation → `transaction, :posted` event
- `:archived` status → `transaction, :archived` event

**`[:double_entry_ledger, :transaction, :created]`**

| Metadata | Description |
|---|---|
| `transaction_id` | Transaction UUID |
| `instance_id` | Ledger instance UUID |
| `status` | Initial status (`:pending` or `:posted`) |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :transaction, :posted]`**

| Metadata | Description |
|---|---|
| `transaction_id` | Transaction UUID |
| `instance_id` | Ledger instance UUID |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :transaction, :archived]`**

| Metadata | Description |
|---|---|
| `transaction_id` | Transaction UUID |
| `instance_id` | Ledger instance UUID |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

#### Account Lifecycle

Emitted from `AccountCommandResponseHandler` and `AccountCommandMapResponseHandler` after a successful Multi result. Dispatch uses `Telemetry.emit_account/2`, which distinguishes created vs updated by comparing `inserted_at` and `updated_at`.

**`[:double_entry_ledger, :account, :created]`**

| Metadata | Description |
|---|---|
| `account_address` | Account address |
| `instance_id` | Ledger instance UUID |
| `type` | Account type (`:asset`, `:liability`, etc.) |
| `currency` | Account currency atom |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :account, :updated]`**

| Metadata | Description |
|---|---|
| `account_address` | Account address |
| `instance_id` | Ledger instance UUID |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

#### Instance Lifecycle

**`[:double_entry_ledger, :instance, :created]`** — emitted from `InstanceStore.create/1` after a successful insert.

| Metadata | Description |
|---|---|
| `instance_id` | Instance UUID |

#### Command Queue Infrastructure

**`[:double_entry_ledger, :instance_processor, :start]`** — emitted from `InstanceProcessor.init/1`.

| Metadata | Description |
|---|---|
| `instance_id` | Instance UUID being processed |

**`[:double_entry_ledger, :instance_processor, :stop]`** — emitted when the InstanceProcessor shuts down after finding no more commands.

| Metadata | Description |
|---|---|
| `instance_id` | Instance UUID that was being processed |

## Defensive Error Handling

The library wraps telemetry emission in `try/rescue`. A failed telemetry call
(e.g., malformed struct passed to `emit_transaction/2`, unexpected status atom)
is silently swallowed and does not propagate to the business logic. Telemetry
is observational — it should never crash a successful ledger operation.

This does **not** apply to `command_process_span/2`, which intentionally
re-raises exceptions from the wrapped function so that business errors surface
normally.

## Phoenix LiveDashboard Integration

The library ships an optional `Telemetry.Metrics` dependency. If you want to
wire the ledger events into Phoenix LiveDashboard or any reporter that consumes
`Telemetry.Metrics` definitions, add `telemetry_metrics` to your app and call
`DoubleEntryLedger.Telemetry.dashboard_metrics/0`.

### Usage

Add the ledger metrics to your existing telemetry module:

```elixir
# lib/my_app_web/telemetry.ex
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration", unit: {:native, :millisecond})
    ] ++ DoubleEntryLedger.Telemetry.dashboard_metrics()
  end

  defp periodic_measurements, do: []
end
```

Reference it in your LiveDashboard route:

```elixir
# lib/my_app_web/router.ex
live_dashboard "/dashboard", metrics: MyAppWeb.Telemetry
```

The same `metrics/0` list works with standalone reporters:

```elixir
# In application.ex children list
TelemetryMetricsPrometheus.Core.init(
  metrics: MyAppWeb.Telemetry.metrics()
)
```

### Metrics returned by `dashboard_metrics/0`

| Type | Event | Tags |
|---|---|---|
| `summary` | `command.process.stop` (duration) | action, source |
| `counter` | `command.enqueue` | action, source |
| `counter` | `command.claim` | — |
| `counter` | `command.retry` | status |
| `counter` | `command.dead_letter` | — |
| `counter` | `command.idempotency_hit` | action, source |
| `counter` | `occ.retry` | module |
| `counter` | `transaction.created` | status |
| `counter` | `transaction.posted` | — |
| `counter` | `transaction.archived` | — |
| `counter` | `account.created` | type, currency |
| `counter` | `account.updated` | — |
| `counter` | `instance.created` | — |

Duration metrics use `unit: {:native, :millisecond}` for human-readable display.

## Writing Custom Handlers

To attach a custom handler for any event, use `:telemetry.attach/4` at
application boot:

```elixir
:telemetry.attach(
  "my-ledger-handler",
  [:double_entry_ledger, :command, :dead_letter],
  &MyApp.Alerts.on_dead_letter/4,
  nil
)
```

The handler function signature is `handler(event_name, measurements, metadata, config)`.
If your handler raises, `:telemetry` automatically detaches it — handler
failures never affect the emitting code.
