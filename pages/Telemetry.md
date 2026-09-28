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

When the batch path processes a command, it emits the same start/stop span
shape and metadata, plus `batch_size`. The reported per-command duration is an
even share of the batch wall time because all commands are written in one
database transaction. Validation failures emit `:stop`, matching the
single-command path; unexpected batch database errors fall back to individual
processing.

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

**`[:double_entry_ledger, :command, :claim]`** — emitted from `Scheduling.claim_batch_for_processing/3` after a processor atomically claims a command. Single-command claims route through the same statement.

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `processor_id` | The claiming lease grant's `owner_id` (`"prefix:node:uuid"`), stable for the owner's whole lifetime |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :retry]`** — emitted from `Scheduling.emit_persisted_failure/3` once the retry write succeeds (not when it dead-letters). An enclosing transaction can still roll back afterwards.

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `status` | Status being set (`:failed`, `:occ_timeout`) |
| `retry_count` | Current retry count |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :dead_letter]`** — emitted from `Scheduling.emit_persisted_failure/3` once the dead-letter write succeeds. An enclosing transaction can still roll back afterwards.

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `error` | Failure class: the text of the persisted error message before its first `": "`. The full message is not in the event; it is on the queue row's `errors` |
| `trace_context` | Consumer-supplied tracing context (map or nil) |

**`[:double_entry_ledger, :command, :recovered]`** — emitted from `Lease.emit_acquisition_events/3` for each queue row that a lease acquisition found left `:processing` by a previous owner and rescheduled. The resulting retry or dead-letter event is emitted as well, so alert on this event to tell "commands are being recovered" apart from "a command failed".

Lease acquisition is the only source: there is no stale-processing sweep, and the event no longer carries `stale_for_seconds`. `reason` is always `:takeover`, but the event does not imply that `[:lease, :acquired]` reported `takeover: true`. It also fires when the acquisition was not a takeover, for example the first acquisition after upgrading from 0.5, or a successor acquiring after a processor gave up on a stalled cleanup and released its lease. It is emitted after the acquisition transaction committed, by whichever process called `emit_acquisition_events/3` — the `InstanceMonitor` for a supervised processor, the caller for a manual `CommandWorker.process_command_with_id/2` — which is not the process that ran the acquisition.

| Metadata | Description |
|---|---|
| `command_id` | Command UUID |
| `instance_id` | Ledger instance UUID |
| `previous_processor_id` | Owner id that held the claim |
| `reason` | `:takeover` |
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

**`[:double_entry_ledger, :batch, :processed]`** — emitted after a batch write
succeeds. It has no metadata and carries these measurements:

| Measurement | Description |
|---|---|
| `batch_size` | Commands submitted to this batch attempt |
| `success_count` | Commands persisted successfully |
| `failure_count` | Commands persisted with a terminal or retry outcome |
| `retry_count` | Stale-write retry attempt used for the successful write |

**`[:double_entry_ledger, :instance_processor, :start]`** — emitted from `InstanceProcessor.init/1`, after the processor has been handed the ledger's lease grant.

| Metadata | Description |
|---|---|
| `instance_id` | Instance UUID being processed |
| `owner_id` | Owner id of the lease this processor holds |

**`[:double_entry_ledger, :instance_processor, :stop]`** — emitted when the InstanceProcessor shuts down after finding no more commands, just before it releases the lease.

| Metadata | Description |
|---|---|
| `instance_id` | Instance UUID that was being processed |

**`[:double_entry_ledger, :instance_processor, :cleanup_stalled]`** — emitted when an `InstanceProcessor` gives the ledger up because the lease row stayed locked across every retry of a cleanup write it owed a queue row. **Alert on this**: it means something that is not a successor is holding the lease row. The rows the processor left `:processing` are rescheduled by the next owner's acquisition, but not necessarily at once — the same lock holder blocks that acquisition too. The processor's own release, when the row lets it through, reports `reason: :cleanup_stalled` on `[:lease, :released]`.

| Metadata | Description |
|---|---|
| `instance_id` | Instance UUID that was being processed |
| `owner_id` | Owner id of the lease that was given up |
| `fencing_token` | Fencing token of that lease |
| `coordination` | What nominated this owner (`:database_polling` or `:manual`) |
| `attempts` | Consecutive `:busy` outcomes before giving up |
| `cleanup` | `:revert` or `:crash_retry` |

#### Ledger Leases

Each ledger has one lease row in PostgreSQL; the owner of that row is the only
process allowed to claim or complete the ledger's queued commands. All four events carry
`instance_id`, `owner_id`, `fencing_token` and `coordination`.

`coordination` says what nominated the owner: the `CommandQueue.Coordinator`
strategy (`:database_polling`) for a supervised processor, or `:manual` for the
short lease `CommandWorker.process_command_with_id/2` takes when it is called
with a string prefix.

Lease events are emitted from several processes, so they can arrive out of
order relative to each other and to command events. `acquired` comes from the
`InstanceMonitor`, or from the caller of a manual
`CommandWorker.process_command_with_id/2`. `renewed` and `lost` come from the
`InstanceProcessor`. `released` comes from the processor (`:drained`,
`:shutdown`, `:cleanup_stalled`), from the acquisition task (`:start_failed`, `:monitor_down`), or
from the manual caller (`:manual`). Correlate by `owner_id` and
`fencing_token` rather than by arrival order. A ledger's first lease starts at
`fencing_token` 1, and every later acquisition of its row increments it, an
orderly handover after a release as well as a takeover of an expired lease.

**`[:double_entry_ledger, :lease, :acquired]`** — emitted from `Lease.emit_acquisition_events/3` after the acquisition transaction committed. A fresh lease and a takeover of an expired one both land here.

| Metadata | Description |
|---|---|
| `instance_id` | Ledger instance UUID |
| `owner_id` | New owner id (`"prefix:node:uuid"`) |
| `fencing_token` | Fencing token granted to this owner |
| `takeover` | `true` when the previous owner expired without releasing |
| `previous_owner_id` | Previous owner id, or `nil` for a fresh lease |
| `orphans` | Number of `:processing` rows this acquisition rescheduled |
| `coordination` | `:database_polling` or `:manual` |

**`[:double_entry_ledger, :lease, :renewed]`** — emitted from `InstanceProcessor` when its idle heartbeat renewed the lease. The heartbeat runs every `lease_ttl / 3` seconds and skips the database while a worker task is in flight, because that task's own transaction refreshes the expiry; so the absence of this event does not mean the lease is not being renewed.

| Metadata | Description |
|---|---|
| `instance_id` | Ledger instance UUID |
| `owner_id` | Owner id |
| `fencing_token` | Fencing token |
| `coordination` | `:database_polling` or `:manual` |

**`[:double_entry_ledger, :lease, :lost]`** — emitted from `InstanceProcessor` when an owner-filtered update matched zero rows because another owner now holds the ledger. The processor stops without writing. **Alert on this.** Contention on the lease row is *not* loss and does not emit this event.

| Metadata | Description |
|---|---|
| `instance_id` | Ledger instance UUID |
| `owner_id` | Owner id that lost the ledger |
| `fencing_token` | Fencing token that no longer matches |
| `coordination` | `:database_polling` or `:manual` |
| `source` | Where the loss was observed: `:renewal`, `:claim`, or `:transaction` |

**`[:double_entry_ledger, :lease, :released]`** — emitted from `Lease.release/3` after the release committed one row. A lease that is never released simply expires after `lease_ttl`, so a missing release event is not an error by itself.

| Metadata | Description |
|---|---|
| `instance_id` | Ledger instance UUID |
| `owner_id` | Owner id |
| `fencing_token` | Fencing token |
| `coordination` | `:database_polling` or `:manual` |
| `reason` | `:drained`, `:shutdown`, `:cleanup_stalled` (the processor gave the ledger up after a cleanup stayed busy, following `[:instance_processor, :cleanup_stalled]`), `:manual`, `:start_failed`, or `:monitor_down` (the acquisition task saw the monitor die before replying) |

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
| `counter` | `command.recovered` | — |
| `counter` | `command.idempotency_hit` | action, source |
| `counter` | `occ.retry` | module |
| `counter` | `transaction.created` | status |
| `counter` | `transaction.posted` | — |
| `counter` | `transaction.archived` | — |
| `counter` | `account.created` | type, currency |
| `counter` | `account.updated` | — |
| `counter` | `instance.created` | — |
| `counter` | `lease.acquired` | takeover |
| `counter` | `lease.renewed` | — |
| `counter` | `lease.lost` | source |
| `counter` | `lease.released` | reason |

`dashboard_metrics/0` does not define metrics for `batch.processed`, the
`instance_processor` events, or `command.process.start`/`exception`; attach a
handler directly if you need those.

Duration metrics use `unit: {:native, :millisecond}` for human-readable display.

## Writing Custom Handlers

The library emits events and stops there. Anything beyond metrics — alerts,
external notifications, audit streams — is the consumer's responsibility.
Attach a handler to the event you care about and do whatever you need in it.

### Example: dead-letter alert handler

Send a PagerDuty alert whenever a command is dead-lettered:

```elixir
# lib/my_app/ledger_alerts.ex
defmodule MyApp.LedgerAlerts do
  @moduledoc "Turns DoubleEntryLedger telemetry events into operational alerts."

  require Logger
  alias MyApp.TaskSupervisor

  @events [
    [:double_entry_ledger, :command, :dead_letter],
    [:double_entry_ledger, :command, :process, :exception]
  ]

  @handler_id "my_app-ledger-alerts"

  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  def detach, do: :telemetry.detach(@handler_id)

  def handle_event([:double_entry_ledger, :command, :dead_letter], _meas, metadata, _config) do
    # Handlers run in the emitting process, so offload blocking work.
    Task.Supervisor.start_child(TaskSupervisor, fn ->
      MyApp.PagerDuty.trigger(
        severity: :high,
        summary: "Ledger command dead-lettered",
        command_id: metadata.command_id,
        # The failure class only, never the full message, which can hold
        # fragments of the command's payload. Read the queue row's `errors`
        # by command_id when the detail is needed.
        error_class: metadata.error
      )
    end)
  end

  def handle_event([:double_entry_ledger, :command, :process, :exception], _meas, metadata, _config) do
    Logger.error("ledger command raised", metadata)
  end
end
```

Wire it up at application boot:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Task.Supervisor, name: MyApp.TaskSupervisor}
    # ... your other children
  ]

  MyApp.LedgerAlerts.attach()

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

### Things to know

- The handler signature is `(event_name, measurements, metadata, config)`.
- Use `attach_many/4` for multiple events — one handler_id, one function.
- Namespace the handler_id with your app name to avoid collisions with other
  libraries that may attach their own handlers.
- **Handlers run synchronously in the process that emitted the event.** Any
  blocking call (HTTP, SMTP, slow DB write) will block the ledger's work.
  Spawn a supervised task for external I/O.
- If a handler raises, `:telemetry` automatically detaches it — a broken
  handler will not be called again, but it also won't crash the emitter.
  Wrap risky work in `try/rescue` if you need the handler to remain attached.
