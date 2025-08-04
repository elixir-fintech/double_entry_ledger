
# Event Sourcing in DoubleEntryLedger

## Overview

DoubleEntryLedger uses an event-sourced architecture where the `Event` record is stored immutably. Each event represents a business action (such as a transaction creation or update) and, once written, is never changed or deleted. This provides a permanent, auditable log of all business activity.

## Event Processing and Replay

- Each event has an associated `EventQueueItem` entry, which tracks the processing status (`:pending`, `:processing`, `:processed`, `:failed`, `:occ_timeout`, `:dead_letter`).
- The event itself is immutable, but the `EventQueueItem` can be updated as the event is processed or retried.
- Replay is enabled by filtering for events with `status == :processed` and using the `updated_at` timestamp from the `EventQueueItem` to determine the chronological order in which events were successfully applied.
- If you need to rerun an account or the entire ledger, you can select all processed events ordered by their completion timestamp and reapply them from the beginning.

## Account Balance Projections

- **Current State**: Account balances are maintained in the `Account` schema with embedded `Balance` structs for both `posted` (finalized) and `pending` (holds/authorizations) amounts, plus a calculated `available` balance.
- **Balance History**: The `BalanceHistoryEntry` schema creates immutable snapshots of account balances at each point in time when they change, providing a complete historical trail.
- **Projection Updates**: As each event is processed, the account balances are updated and a new `BalanceHistoryEntry` is created to capture the state change.
- **Audit Trail**: The balance history entries are append-only and linked to both the account and the specific entry that caused the change, enabling precise auditing and reconciliation.

## Benefits

- **Auditability**: Every business action is recorded as an immutable event, providing a complete audit trail.
- **Reproducibility**: The entire system state can be rebuilt at any time by replaying all processed events in order.
- **Resilience**: If a bug or data corruption occurs, you can restore a consistent state by replaying the event log.
- **Transparency**: The event log and projections provide a clear, chronological record of all actions and their effects.

## Summary

DoubleEntryLedger's event-sourced design ensures that all business actions are permanently recorded as immutable events. The system maintains account balance projections through the `Account` schema with embedded `Balance` structs and preserves complete historical changes via `BalanceHistoryEntry` records. The `EventQueueItem` status tracking enables safe retries and full replay capabilities by timestamp ordering. This architecture guarantees auditability, recoverability, and transparency for all accounting operations.

## Immutability Enforcement (TODO)

Currently immutability is not enforced on the database level. On the application level an `Event` can't be changed or deleted and all `Balance` updates to an `Account` are driven by events, including the adding of `BalanceHistoryEntry`. The best way to enforce immutability in Postgres would be through the implementation of Row Level Security which enables fine grained control over actions per table.
