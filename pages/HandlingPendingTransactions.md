# Handling Pending Transactions

The Double Entry Ledger supports robust handling of **pending** transactions, allowing you to create holds, authorizations, or transactions that are not immediately finalized. Pending transactions can later be posted (finalized) or archived (canceled), supporting workflows such as payment authorizations, delayed settlements, or reservation systems.

This guide explains how to work with pending transactions in both synchronous and asynchronous scenarios, and how state transitions (`:pending` → `:posted` or `:archived`) are managed.

---

## Transaction States

A transaction in the ledger can be in one of the following states:

- `:pending` — The transaction is a draft, hold, or authorization. It can be modified, posted, or archived.
- `:posted` — The transaction is finalized and cannot be changed.
- `:archived` — The transaction is canceled or superseded and cannot be changed.

---

## Creating a Pending Transaction (Synchronous)

You can create a pending transaction synchronously by submitting an event with `status: :pending` and processing it immediately.  
**Always include `source` and a unique `source_idempk` for idempotency.**

```elixir
event_params = %{
  instance_id: instance.id,
  source: "checkout",
  source_idempk: "order-123",
  source_data: %{description: "Hold funds for order"},
  action: :create,
  transaction_data: %{
    status: :pending,
    entries: [
      %{account_id: cash.id, amount: 1000_00, currency: :USD},
      %{account_id: liability.id, amount: 1000_00, currency: :USD}
    ]
  }
}

{:ok, transaction, event} =
  DoubleEntryLedger.EventStore.process_from_event_params(event_params)

IO.inspect(transaction.status) # :pending
```

---

## Creating a Pending Transaction (Asynchronous)

To create a pending transaction asynchronously, submit the event to the event queue. The event will be processed in the background:

```elixir
event_params = %{
  instance_id: instance.id,
  source: "checkout",
  source_idempk: "order-123",
  source_data: %{description: "Hold funds for order"},
  action: :create,
  transaction_data: %{
    status: :pending,
    entries: [
      %{account_id: cash.id, amount: 1000_00, currency: :USD},
      %{account_id: liability.id, amount: 1000_00, currency: :USD}
    ]
  }
}

{:ok, event} = DoubleEntryLedger.EventStore.create(event_params)
# The event will be processed asynchronously by the event queue.
```

You can later check the event and transaction status:

```elixir
event = DoubleEntryLedger.EventStore.get_by_id(event.id)
transaction_id = event.processed_transaction_id
transaction = DoubleEntryLedger.TransactionStore.get_by_id(transaction_id)
IO.inspect(transaction.status) # :pending (until posted or archived)
```

---

## Updating a Pending Transaction (Post or Archive)

To update a pending transaction (for example, to post or archive it), submit an **update event**.  
**Important:**  

- The update event must include the same `source` and `source_idempk` as the original event.
- The update event must have a unique `update_idempk` (unique per update for the original event).
- The original transaction must still be in the `:pending` state.

### Example: Posting (Finalizing) a Pending Transaction

```elixir
update_event_params = %{
  instance_id: instance.id,
  source: "checkout",
  source_idempk: "order-123",      # must match the original event
  update_idempk: "order-123-post", # unique for this update
  source_data: %{description: "Finalize order"},
  action: :update,
  transaction_data: %{
    status: :posted
  }
}

# Synchronous processing:
{:ok, transaction, event} =
  DoubleEntryLedger.EventStore.process_from_event_params(update_event_params)

IO.inspect(transaction.status) # :posted

# Or, for async processing:
{:ok, event} = DoubleEntryLedger.EventStore.create(update_event_params)
```

### Example: Archiving (Canceling) a Pending Transaction

```elixir
archive_event_params = %{
  instance_id: instance.id,
  source: "checkout",
  source_idempk: "order-123",         # must match the original event
  update_idempk: "order-123-archive", # unique for this update
  source_data: %{description: "Cancel order"},
  action: :update,
  transaction_data: %{
    status: :archived
  }
}

# Synchronous processing:
{:ok, transaction, event} =
  DoubleEntryLedger.EventStore.process_from_event_params(archive_event_params)

IO.inspect(transaction.status) # :archived

# Or, for async processing:
{:ok, event} = DoubleEntryLedger.EventStore.create(archive_event_params)
```

---

## State Transition Rules

- Only transactions in the `:pending` state can be posted or archived.
- Once a transaction is `:posted` or `:archived`, it cannot be changed.
- All transitions are validated by the ledger and will fail if not allowed.
- Update events must reference the original event by `source` and `source_idempk`, and provide a unique `update_idempk`.
- Any update event for a :posted or :archived transaction will not be processed.

---

## Impact of Pending Transactions on Available Account Balance

Pending transactions play a crucial role in determining the **available balance** of an account, especially in scenarios where funds are reserved but not yet finalized (e.g., payment authorizations, holds, or reservations).

### How Pending Transactions Affect Balances

- **Posted Balance:** The sum of all amounts from transactions in the `:posted` state. This is the "official" ledger balance and is stored in the `posted` embedded struct on the account.
- **Pending Balance:** The sum of all amounts from transactions in the `:pending` state. This represents funds that are reserved or on hold and is stored in the `pending` embedded struct on the account.
- **Available Balance:** The calculated balance that accounts for both posted and pending transactions. This is stored in the `available` field on the account struct and is automatically updated by the ledger.

  For credit accounts, the available balance is calculated as: `available = posted.amount - pending.debit`
  For debit accounts, the available balance is calculated as: `available = posted.amount - pending.credit`

  The exact calculation may depend on the account's normal balance and configuration, but the ledger ensures that the `available` field reflects the correct value.

### Example: Pending Transaction Subtracting Money

Suppose your account has a posted balance of $1,000.  
You create a pending transaction to reserve $200 for a payment:

```elixir
event_params = %{
  instance_id: instance.id,
  source: "checkout",
  source_idempk: "order-456",
  source_data: %{description: "Hold funds for payment"},
  action: :create,
  transaction_data: %{
    status: :pending,
    entries: [
      %{account_id: cash.id, amount: -200_00, currency: :USD},
      %{account_id: liability.id, amount: -200_00, currency: :USD}
    ]
  }
}

{:ok, event} = DoubleEntryLedger.EventStore.create(event_params)
```

- The `cash` account now has a pending transaction subtracting $200.
- The **available balance** for `cash` is now $800, even though the posted balance is still $1,000.
- If the transaction is later posted, the posted balance will decrease by $200 and the pending balance will be cleared.
- If the transaction is archived, the pending hold is released and the available balance returns to $1,000.

### Querying Balances

You can retrieve the account struct and inspect its balance fields:

```elixir
account = DoubleEntryLedger.AccountStore.get_by_id(cash.id)
IO.inspect(account.posted)    # The posted (finalized) balance struct
IO.inspect(account.pending)   # The sum of all pending transactions (pending balance struct)
IO.inspect(account.available) # The available balance as an integer
```

- `account.posted.amount` gives the posted balance.
- `account.pending.amount` gives the pending balance.
- `account.available` gives the available balance, which is automatically calculated and updated by the ledger.

> **Note:**  
> Pending transactions that subtract money (negative amounts) immediately reduce the available balance, even before they are posted. This is essential for scenarios like card authorizations, hotel reservations, or any workflow where funds must be reserved before final settlement.

### Why This Matters

- **Prevents overspending:** Pending transactions ensure that reserved funds are not double-spent.
- **Accurate reporting:** Users and systems can see both posted and available balances, reflecting real-world constraints.
- **Consistency:** The ledger enforces that only available funds can be used for new transactions, taking into account all pending holds.

---

## Example Workflow

1. **Create a pending transaction (hold):**

    ```elixir
    {:ok, event} = DoubleEntryLedger.EventStore.create(%{
        instance_id: instance.id,
        source: "checkout",
        source_idempk: "order-123",
        source_data: %{description: "Hold funds for order"},
        action: :create,
        transaction_data: %{
        status: :pending,
        entries: [
            %{account_id: cash.id, amount: 1000_00, currency: :USD},
            %{account_id: liability.id, amount: 1000_00, currency: :USD}
        ]
        }
    })
    ```

2. **Update the pending transaction's entries (e.g., change the amount):**

    ```elixir
    {:ok, event} = DoubleEntryLedger.EventStore.create(%{
        instance_id: instance.id,
        source: "checkout",
        source_idempk: "order-123",            # must match the original event
        update_idempk: "order-123-update-1",   # unique for this update
        source_data: %{description: "Update order amount"},
        action: :update,
        transaction_data: %{
        # status is still :pending
        entries: [
            %{account_id: cash.id, amount: 1200_00, currency: :USD},
            %{account_id: liability.id, amount: 1200_00, currency: :USD}
        ]
        }
    })
    ```

    > **Note:**  
    > When updating the entries of a pending transaction:
    >
    > - The number of entries must remain the same as in the original transaction.
    > - The entries must reference the same accounts as the original transaction (account IDs and currencies must match).
    > - All other double entry ledger rules still apply: the transaction must remain balanced, and only transactions in the `:pending` state can be updated.

3. **Post (finalize) the transaction:**

    ```elixir
    {:ok, event} = DoubleEntryLedger.EventStore.create(%{
        instance_id: instance.id,
        source: "checkout",
        source_idempk: "order-123",
        update_idempk: "order-123-post",
        source_data: %{description: "Finalize order"},
        action: :update,
        transaction_data: %{status: :posted}
    })
    ```

4. **Or archive (cancel) the transaction:**

    ```elixir
    {:ok, event} = DoubleEntryLedger.EventStore.create(%{
        instance_id: instance.id,
        source: "checkout",
        source_idempk: "order-123",
        update_idempk: "order-123-archive",
        source_data: %{description: "Cancel order"},
        action: :update,
        transaction_data: %{status: :archived}
    })
    ```

---

## Notes

- The `update_idempk` field must be unique for each update event and must be used together with the original `source` and `source_idempk`.
- All transitions and validations are handled by the ledger, ensuring data integrity and auditability.
- Both synchronous and asynchronous flows are supported; use the one that fits your application's needs.

---

For more details, see:

- [DoubleEntryLedger.Event](DoubleEntryLedger.Event.html)
- [DoubleEntryLedger.Transaction](DoubleEntryLedger.Transaction.html)
- [DoubleEntryLedger.EventStore](DoubleEntryLedger.EventStore.html)
