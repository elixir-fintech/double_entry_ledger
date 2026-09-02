# Asynchronous Processing with the Command Queue

DoubleEntryLedger submits work to an immutable `Command` table and processes it through a built-in command queue. You decide whether to wait for the projection to finish (`CommandApi.process_from_params/2`) or store the command and let the queue finish it in the background (`CommandApi.create_from_params/1`). This guide focuses on the asynchronous path.

## How the queue is organized

- **Command submission:** Commands are written through `DoubleEntryLedger.Apis.CommandApi`. Each command carries a `CommandQueueItem` record with status `:pending`, `:processing`, `:processed`, `:failed`, `:occ_timeout`, or `:dead_letter`.
- **Supervision:** `DoubleEntryLedger.CommandQueue.Supervisor` starts the scheduler stack (registry, dynamic supervisors, and workers). `InstanceMonitor` polls for instances with pending commands and ensures each has an `InstanceProcessor`.
- **Processing:** An `InstanceProcessor` atomically claims commands, invokes the appropriate worker module, and writes the resulting `JournalEvent`, transactions, entries, and balance history. Journal-event relationships are stored synchronously through direct foreign keys.
- **Optional batching:** With `batch_enabled: true`, compatible create/update transaction commands are claimed and written together. Account commands and batches that encounter unexpected database errors fall back to the single-command path.
- **Crash recovery:** Each worker task is monitored via `Process.monitor/1`. If the task crashes unexpectedly, the `InstanceProcessor` receives a `:DOWN` message and schedules a retry for the command automatically — no manual intervention required.
- **Retries:** Workers distinguish validation failures (marked as dead letters) from transient OCC or database errors (scheduled with exponential backoff). The synchronous OCC loop uses the top-level runtime `max_retries` and `retry_interval`; queued retry delays use the compiled `:command_queue` settings described below. Exhausted retries land in `:dead_letter` for manual inspection.

## Submitting commands asynchronously

Use the same request payload you would send synchronously but call `CommandApi.create_from_params/1`. The command is persisted, assigned a queue item, and returned immediately.

```elixir
alias DoubleEntryLedger.Apis.CommandApi

command = %{
  "instance_address" => instance.address,
  "action" => "create_transaction",
  "source" => "billing",
  "source_idempk" => "async-payment-1",
  "payload" => %{
    status: :posted,
    entries: [
      %{"account_address" => cash.address, "amount" => 1_000_00, "currency" => :USD},
      %{"account_address" => revenue.address, "amount" => 1_000_00, "currency" => :USD}
    ]
  }
}

{:ok, processed_command} = CommandApi.create_from_params(command)
processed_command.command_queue_item.status
# => :pending
```

At this point the command is durable, but the associated transaction and journal event do not exist yet.

## Monitoring processing

`InstanceMonitor` continuously scans for pending commands and spins up processors per instance. Processors transition commands through statuses:

1. `:pending` → `:processing` when the worker claims the command.
2. `:processing` → `:processed` when projections succeed.
3. `:processing` → `:failed`, `:occ_timeout`, or `:dead_letter` when something goes wrong.

Use `DoubleEntryLedger.Stores.CommandStore` to inspect queue progress:

```elixir
alias DoubleEntryLedger.Stores.CommandStore

command = CommandStore.get_by_id(command.id)
command.command_queue_item.status

{:ok, {commands, meta}} =
  CommandStore.list_for_instance(instance, %{first: 20})
```

When you need the resulting transaction or account, wait until the `CommandQueueItem` shows `:processed`, then query the projections normally (e.g., `TransactionStore.get_by_id/1`, `AccountStore.get_by_address/2`, or `JournalEventStore` helpers).

## Configuration knobs

Tuning happens under the `:command_queue` config namespace (kept for backwards compatibility):

```elixir
config :double_entry_ledger, :command_queue,
  poll_interval: 5_000,
  pending_fetch_limit: 64,
  max_retries: 5,
  base_retry_delay: 30,
  max_retry_delay: 3_600,
  processor_name: "command_queue"

config :double_entry_ledger,
  batch_enabled: false,
  batch_size: 8,
  max_batch_retries: 3
```

- `poll_interval` – how often `InstanceMonitor` looks for pending work.
- `pending_fetch_limit` – how many queue IDs a processor fetches per database read. When batching is enabled, use a value at least as large as, and preferably a multiple of, `batch_size`.
- `max_retries`, `base_retry_delay`, `max_retry_delay` – queue retry/backoff behaviour. These values are compiled into `CommandQueue.Scheduling`; change them before compiling the dependency.
- `processor_name` – used in queue item metadata to identify workers.
- `batch_enabled` – live switch for batched transaction processing; account commands remain on the single-command path.
- `batch_size` – maximum number of compatible transaction commands per write batch.
- `max_batch_retries` – stale-write retries before the batch is recursively split.

DoubleEntryLedger 0.5.0 does not depend on or supervise a third-party job
runner. The command queue uses its own `InstanceMonitor` and
`InstanceProcessor` supervision tree.

## Error handling and retries

- **Validation errors** (bad payloads, missing accounts, unbalanced entries) mark the command as `:dead_letter` with the reason recorded on the queue item. They are not retried.
- **Optimistic concurrency conflicts** (stale account/transaction rows) mark the queue item as `:occ_timeout` which is retried automatically.
- **Unexpected exceptions** mark the queue item as `:failed` and are retried using exponential backoff until `max_retries` is reached.
- **Manual intervention:** Inspect the recorded `errors` array on `CommandQueueItem` or the `PendingTransactionLookup` table when updates fail because the original transaction is still pending.

## Summary

- Queue commands via `CommandApi.create_from_params/1`; each command is immutable and idempotent.
- `CommandQueueItem` tracks the background lifecycle; workers process commands per instance with OCC and retries.
- Monitor queue state through `CommandStore` and read projections through the existing stores once the queue item reaches `:processed`.
- Tune queue reads and retry behaviour through `:command_queue`; opt into transaction batching with the top-level batch settings.

For more details, explore:

- `DoubleEntryLedger.CommandQueue.InstanceMonitor`
- `DoubleEntryLedger.CommandQueue.InstanceProcessor`
- Worker modules under `DoubleEntryLedger.Workers.CommandWorker`
- `DoubleEntryLedger.Stores.CommandStore`
