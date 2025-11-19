# Event Sourcing in DoubleEntryLedger

## Overview

Commands are the write-ahead log of DoubleEntryLedger. Each call to `DoubleEntryLedger.Apis.CommandApi` creates an immutable `Command` record containing:

- The original request payload (`command_map`)
- Idempotency keys (`source`, `source_idempk`, optional `update_idempk`)
- A `CommandQueueItem` that tracks processing attempts and outcomes

Commands are never updated; only the queue item changes as work progresses. When a worker finishes successfully it emits a `JournalEvent` plus the necessary projections (transactions, entries, balance history, updated accounts) and links them together for auditing. JournalEvents are immutable and act as the event source for the ledger. Commands on the other hand could potentially be removed once they are processed.

## Processing and replay

- **Statuses:** `CommandQueueItem` drives the lifecycle (`:pending`, `:processing`, `:processed`, `:failed`, `:occ_timeout`, `:dead_letter`). Each transition records timestamps, processor IDs, retry counts, and error payloads.
- **Replay order:** For most read scenarios it is easiest to replay `JournalEvent` records (ordered by `inserted_at`) because they capture the canonical “business fact” for both account and transaction commands.
- **Idempotency:** `DoubleEntryLedger.Command.IdempotencyKey` hashes `(instance_id, source, source_idempk, update_idempk)` to guarantee that duplicate requests are not processed again. `PendingTransactionLookup` ties updates to the transaction created by the original pending command.

## Account balance projections

- **Account state:** The `Account` schema stores embedded `Balance` structs for `posted` and `pending` values plus an `available` integer that reflects the correct sign based on the account’s normal balance.
- **Balance history:** `BalanceHistoryEntry` rows are appended for every entry mutation so you can audit how each command changed an account’s posted or pending amounts. Each history row links to the originating `Entry`, which links back to the `Transaction`, `JournalEvent`, and `Command`.
- **Consistency checks:** `InstanceStore.validate_account_balances/1` recalculates sums across accounts, ensuring debits and credits match per currency for both posted and pending projections.

## Benefits

- **Auditability:** Immutable commands, journal events, and balance history entries make it trivial to trace any change back to the originating API call.
- **Rebuildability:** Replay journal events to reconstruct accounts, transactions, and balances if you need to recover from a bug or rebuild analytics projections.
- **Resilience:** Command queue retries isolate transient failures while keeping the authoritative log append-only.
- **Transparency:** `JournalEventTransactionLink` and `JournalEventAccountLink` tables capture every relationship so you can answer “which command touched this transaction/account?” instantly.

## Immutability considerations

Application logic enforces immutability today: commands and journal events are only appended, balance history is append-only, and updates to `Account` or `Transaction` rows can only happen through the command workers. PostgreSQL row-level security or restricted grants can make this enforcement stricter if your deployment shares a database with other applications.
