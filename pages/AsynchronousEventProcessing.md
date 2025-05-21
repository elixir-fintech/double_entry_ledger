# Asynchronous Processing with the Event Queue

The Double Entry Ledger supports robust asynchronous event processing using its built-in event queue system. This allows you to submit events for processing and let the system handle them in the background, ensuring reliability, concurrency, and fault tolerance.

---

## How the Event Queue Works

- **Event Submission:** You create and submit events (transactions) to the ledger. These events are stored in the database with a status of `:pending`.
- **Event Queue Supervision:** The event queue is managed by a supervisor tree, including a registry, dynamic supervisors, and instance monitors.
- **Instance Monitoring:** The `InstanceMonitor` periodically scans for instances with pending events and ensures an `InstanceProcessor` is running for each.
- **Instance Processing:** Each `InstanceProcessor` claims and processes events for its instance, updating their status and creating the corresponding transactions.
- **Retries and Error Handling:** Failed events are retried with exponential backoff. Terminal failures are moved to a dead letter state for inspection.

---

## Submitting Events for Asynchronous Processing

You can submit events using the same API as for synchronous processing. The difference is that you do **not** wait for the transaction to be processed immediately. Instead, the event is queued and processed by the background workers.

```elixir
event_params = %{
  instance_id: instance.id,
  source: "external_system",
  source_idempk: "unique-id-123",
  source_data: %{description: "Async payment"},
  action: :create,
  transaction_data: %{
    status: :posted,
    entries: [
      %{account_id: cash.id, amount: 1000_00, currency: :USD},
      %{account_id: revenue.id, amount: 1000_00, currency: :USD}
    ]
  }
}

{:ok, event} = DoubleEntryLedger.EventStore.create(event_params)
# The event is now in the queue and will be processed asynchronously.
```

- The returned `event` will have status `:pending`.
- You can track the event's status by querying it later.

---

## Monitoring and Processing Events

The event queue system will automatically:

- Detect new pending events.
- Start processors for each instance as needed.
- Process events in order, updating their status to `:processing`, then `:processed` or `:failed`.
- Retry failed events according to the configured backoff and retry policy.

You do **not** need to manually start or manage processors; this is handled by the supervisor and monitor modules.

---

## Checking Event and Transaction Status

You can check the status of an event at any time:

```elixir
event = DoubleEntryLedger.EventStore.get_by_id(event.id)
IO.inspect(event.status)
```

To get all events for an instance:

```elixir
events = DoubleEntryLedger.EventStore.list_all_for_instance(instance.id)
```

To get the transaction created by a processed event:

```elixir
event = DoubleEntryLedger.EventStore.get_by_id(event.id)
transaction_id = event.processed_transaction_id
transaction = DoubleEntryLedger.TransactionStore.get_by_id(transaction_id)
```

---

## Configuration

You can configure the event queue poll interval and other settings in your application config:

```elixir
config :double_entry_ledger, :event_queue,
  poll_interval: 5_000 # milliseconds
```

---

## Error Handling and Retries

- If an event fails to process, it will be retried automatically with exponential backoff.
- If it fails terminally, it will be marked as `:dead_letter` for manual inspection.
- You can inspect errors and retry or fix events as needed.

---

## Summary

- Submit events using `DoubleEntryLedger.EventStore.create/1` for asynchronous processing.
- The event queue system will process events in the background.
- Monitor event and transaction status using the EventStore and TransactionStore APIs.
- Configure queue behavior via application settings.
- The system handles retries, error states, and ensures reliable, exactly-once processing.

For more details, see:

- [DoubleEntryLedger.EventQueue.Supervisor](DoubleEntryLedger.EventQueue.Supervisor.html)
- [DoubleEntryLedger.EventQueue.InstanceMonitor](DoubleEntryLedger.EventQueue.InstanceMonitor.html)
- [DoubleEntryLedger.EventQueue.InstanceProcessor](DoubleEntryLedger.EventQueue.InstanceProcessor.html)
