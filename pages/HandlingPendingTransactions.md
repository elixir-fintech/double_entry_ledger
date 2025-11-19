# Handling Pending Transactions

DoubleEntryLedger models holds, authorizations, and delayed settlements through the `:pending` transaction state. Pending transactions are first-class: they reserve balance immediately, can be updated while pending, and must eventually be posted (finalized) or archived (canceled). This guide explains how to create, update, and monitor pending commands using the public APIs.

## Transaction states

Transactions (`DoubleEntryLedger.Transaction`) have three valid states:

- `:pending` – drafts/holds/authorizations. Entries affect the account’s pending balance and can be edited or canceled.
- `:posted` – finalized. Entries affect the posted balance and cannot be changed.
- `:archived` – canceled or expired pending transactions. They no longer affect pending balances and cannot be revived.

Only pending transactions can transition to another state. Posted or archived rows are immutable.

## Creating a pending transaction synchronously

Use `DoubleEntryLedger.Apis.CommandApi.process_from_params/2` with `status: :pending`. Provide string keys (matching the JSON API) plus signed amounts.

```elixir
alias DoubleEntryLedger.Apis.CommandApi

command = %{
  "instance_address" => instance.address,
  "action" => "create_transaction",
  "source" => "checkout",
  "source_idempk" => "order-123",
  "payload" => %{
    status: :pending,
    entries: [
      %{"account_address" => cash.address, "amount" => -100_00, "currency" => :USD},
      %{"account_address" => liability.address, "amount" => -100_00, "currency" => :USD}
    ]
  }
}

{:ok, transaction, processed_command} = CommandApi.process_from_params(command)
transaction.status
# => :pending
processed_command.command_queue_item.status
# => :processed
```

The transaction is persisted immediately, pending balances are updated, and a `PendingTransactionLookup` row links the `source/source_idempk` tuple to the new transaction so future updates can find it quickly.

## Queueing a pending transaction for asynchronous processing

Call `CommandApi.create_from_params/1` with the same payload to enqueue the work instead of waiting synchronously:

```elixir
{:ok, queued_command} = CommandApi.create_from_params(event)
queued_command.command_queue_item.status
# => :pending
```

Background processors (InstanceMonitor → InstanceProcessor) will pick up the command, mark it as `:processing`, persist the transaction, and finally set the queue item to `:processed`. Inspect progress with `DoubleEntryLedger.Stores.CommandStore.get_by_id/1`.

## Updating a pending transaction

Updates must reference the same `source` and `source_idempk` as the original pending command and supply a unique `update_idempk` per update. `PendingTransactionLookup` enforces that the original transaction is still pending before allowing the update.

### Posting (finalizing) the hold

```elixir
CommandApi.process_from_params(%{
  "instance_address" => instance.address,
  "action" => "update_transaction",
  "source" => "checkout",
  "source_idempk" => "order-123",      # tie back to the original hold
  "update_idempk" => "order-123-post", # unique per update
  "payload" => %{status: :posted}
})
```

The worker loads the transaction referenced by `PendingTransactionLookup`, transitions it from `:pending` to `:posted`, and writes a new `JournalEvent`.

### Archiving (canceling) the hold

```elixir
CommandApi.process_from_params(%{
  "instance_address" => instance.address,
  "action" => "update_transaction",
  "source" => "checkout",
  "source_idempk" => "order-123",
  "update_idempk" => "order-123-void",
  "payload" => %{status: :archived}
})
```

Only pending transactions can be archived. If the create command is still processing or previously failed, the update worker will revert the update command to `:pending` or schedule a retry until the create completes successfully.

### Editing entries while still pending

Pending updates may also include `entries` with the same account addresses/currencies as the original transaction. The ledger enforces:

- Entry count and ordering must match the original pending transaction.
- Account addresses and currencies are immutable.
- Signed amounts may change as long as the transaction remains balanced per currency.

## Impact on account balances

- **Posted (`account.posted`)** – sums entries for posted transactions.
- **Pending (`account.pending`)** – sums entries for pending transactions.
- **Available (`account.available`)** – derived from the posted and pending balances respecting the account’s normal balance and will always be equal or lower to the posted balance. For an account with debit normal balance, a pending credit will lower the available balance as this is an expectation of a payout from the account. A pending debit on the other hand will not affect the balance, as this is an expectation of a potential inflow that is not guaranteed until the transaction is posted.

Inspect balances via `DoubleEntryLedger.Stores.AccountStore.get_by_address/2` or any other account lookup.

```elixir
alias DoubleEntryLedger.Stores.AccountStore

account = AccountStore.get_by_address(instance.address, cash.address)
account.posted.amount
account.pending.amount
account.available
```

Balance history (`DoubleEntryLedger.BalanceHistoryEntry`) records every mutation and links back to the originating entry and command for auditing.

## Example workflow

1. **Create a hold**

   ```elixir
   {:ok, hold, _command} = CommandApi.process_from_params(event)
   ```

2. **Modify the pending amount** (optional)

   ```elixir
   CommandApi.process_from_params(%{
     "instance_address" => instance.address,
     "action" => "update_transaction",
     "source" => "checkout",
     "source_idempk" => "order-123",
     "update_idempk" => "order-123-adjust",
     "payload" => %{
       status: :pending,
       entries: [
         %{"account_address" => cash.address, "amount" => -120_00, "currency" => :USD},
         %{"account_address" => liability.address, "amount" => -120_00, "currency" => :USD}
       ]
     }
   })
   ```

3. **Post or archive when the business flow completes** (examples above).

Throughout the workflow you can inspect the command status via `CommandStore`, the live transaction via `DoubleEntryLedger.Stores.TransactionStore.get_by_id/1`, or the journal via `DoubleEntryLedger.Stores.JournalEventStore`.

## Notes

- Always include `source`, `source_idempk`, and (for updates) `update_idempk`. These keys provide idempotency and allow `PendingTransactionLookup` to find the correct transaction.
- Only `:pending` transactions can be updated. Attempts to update `:posted` or `:archived` transactions will be rejected.
- If the original pending command fails, the update command is moved back to `:pending` or retried so the system never posts a non-existent transaction.
- Both synchronous (`process_from_params/2`) and asynchronous (`create_from_params/1`) flows support pending transactions; choose based on whether the caller must wait for projection results.

Use these patterns to model card authorizations, hotel holds, or any other business flow where money must be reserved before final settlement.
