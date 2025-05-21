# Double Entry Ledger internals and basic setup

## Introduction

A double entry ledger is the foundation of reliable accounting systems. Every transaction affects at least two accounts, and the sum of all debits and credits must always be equal. This ensures the ledger remains balanced and provides a robust audit trail.

This document explains how the double entry ledger in this codebase works, focusing on:

- The necessity of different account types to safely introduce value
- How the system uses debit and credit internally
- How you interact with the ledger using signed amounts (not explicit debits/credits)
- How the system translates signed amounts into debits and credits
- **How to set up an instance, accounts, and process events synchronously**

---

## Core Principles of Double Entry Accounting

- **Every transaction must balance:** The sum of all debits and credits in a transaction must be equal (per currency).
- **No value from nothing:** You cannot simply "add" or "remove" value from the system. To introduce value (e.g., initial capital), you must use at least two accounts of different types (e.g., Asset and Equity).
- **Account types matter:** The five standard types are:
  - **Asset** (e.g., cash, inventory)
  - **Liability** (e.g., loans, payables)
  - **Equity** (e.g., owner's capital)
  - **Revenue** (e.g., sales)
  - **Expense** (e.g., rent, salaries)

---

## Account Types and Introducing Value

To safely introduce value into the ledger, you must use accounts of different types. For example:

- **Initial Capital Injection:**
  - Increase an Asset account (e.g., Cash)
  - Increase an Equity account (e.g., Owner's Equity)

In accounting terms, this means:

- **Debit** the Asset (Cash) account (increases assets)
- **Credit** the Equity (Owner's Equity) account (increases equity)

**Debits and credits balance:**

- Debit Cash $1000
- Credit Owner's Equity $1000

---

## Internal Handling: Debit and Credit

Internally, the ledger uses **debit** and **credit** entries, based on the account’s normal balance:

- **Assets/Expenses:** Normal balance is debit
- **Liabilities/Equity/Revenue:** Normal balance is credit

When you submit a signed amount, the system:

- Determines if the amount should be recorded as a debit or credit based on the account type and sign
- Ensures the sum of all debits and credits is equal (per currency)
- Rejects any transaction that does not balance

---

## How to Use Signed Amounts

When creating an event, **do not think in terms of debit or credit**.  
Instead, think about whether you want to **add to** or **subtract from** the account’s balance:

- **Positive amount:** You want to increase the account’s balance.
- **Negative amount:** You want to decrease the account’s balance.

**The system will translate your intent into the correct debit or credit entry based on the account type.**

---

## Examples

### 1. Initial Capital Injection

Suppose you want to inject $1000 as initial capital:

| Account         | Type    | Amount (USD) | User Intent           | Ledger Translation      |
|-----------------|---------|--------------|-----------------------|------------------------|
| Cash            | Asset   | +1000        | Add $1000 to Cash     | Debit Cash $1000       |
| Owner’s Equity  | Equity  | +1000        | Add $1000 to Equity   | Credit Equity $1000    |

Ledger Translation: **Debits = Credits = $1000 (Balanced)**

### 2. Moving Value Between Asset Accounts

Suppose you move $500 from Checking to Savings:

| Account         | Type    | Amount (USD) | User Intent                | Ledger Translation      |
|-----------------|---------|--------------|----------------------------|------------------------|
| Checking        | Asset   | -500         | Subtract $500 from Checking| Credit Checking $500   |
| Savings         | Asset   | +500         | Add $500 to Savings        | Debit Savings $500     |

Ledger Translation: **Debits = Credits = $500 (Balanced)**

### 3. Sale with Tax

Suppose you receive $1000 in cash, of which $800 is revenue and $200 is tax payable:

| Account         | Type      | Amount (USD) | User Intent                | Ledger Translation      |
|-----------------|-----------|--------------|----------------------------|------------------------|
| Cash            | Asset     | +1000        | Add $1000 to Cash          | Debit Cash $1000       |
| Revenue         | Revenue   | +800         | Add $800 to Revenue        | Credit Revenue $800    |
| Tax Payable     | Liability | +200         | Add $200 to Tax Payable    | Credit Tax Payable $200|

Ledger Translation: **Debits = Credits = $1000 (Balanced)**

---

## Multi-Account Transactions

Events can involve more than two accounts, as long as the sum of all debits equals the sum of all credits (per currency).  
You only need to specify whether you are adding or subtracting value from each account; the system will handle the rest.

---

## Setting Up and Using the Ledger (Synchronous Example)

Below is a step-by-step guide to set up an instance, create accounts, and process events synchronously.

### 1. Create a Ledger Instance

```elixir
{:ok, instance} = DoubleEntryLedger.InstanceStore.create(%{
  name: "Main Ledger",
  description: "Ledger for ACME Corp"
})
```

### 2. Create Accounts

```elixir
{:ok, cash} = DoubleEntryLedger.AccountStore.create(%{
  name: "Cash",
  instance_id: instance.id,
  currency: :USD,
  type: :asset
})

{:ok, savings} = DoubleEntryLedger.AccountStore.create(%{
  name: "Savings",
  instance_id: instance.id,
  currency: :USD,
  type: :asset
})

{:ok, equity} = DoubleEntryLedger.AccountStore.create(%{
  name: "Owner's Equity",
  instance_id: instance.id,
  currency: :USD,
  type: :equity
})
```

### 3. Create and Process an Event Synchronously

You can process an event synchronously by calling the event store directly:

```elixir
event_params = %{
  instance_id: instance.id,
  source: "manual",
  source_idempk: "idempotent-id-1",
  source_data: %{
    description: "Initial capital injection"
  }
  action: :create,
  transaction_data: %{
    status: :posted,
    entries: [
      %{account_id: cash.id, amount: 1000_00, currency: :USD},
      %{account_id: equity.id, amount: 1000_00, currency: :USD}
    ]
  }
}

{:ok, transaction, event} =
  DoubleEntryLedger.EventStore.process_from_event_params(event_params)
```

- Both amounts are positive, indicating you want to add value to both accounts.
- The system will translate these into a debit for Cash and a credit for Equity, ensuring the transaction is balanced.

### 4. Query Account Balances

```elixir
{:ok, cash_balance} = DoubleEntryLedger.AccountStore.get_balance_history(cash.id)
{:ok, equity_balance} = DoubleEntryLedger.AccountStore.get_balance_history(equity.id)
```

### 5. Move Value Between Accounts

```elixir
event_params = %{
  instance_id: instance.id,
  action: :create,
  source: "manual",
  source_idempk: "idempotent-id-2",
  source_data: %{
    description: "Move funds from Cash to Savings"
  }
  transaction_data: %{
    status: :posted,
    entries: [
      %{account_id: cash.id, amount: -500_00, currency: :USD},
      %{account_id: savings.id, amount: 500_00, currency: :USD}
    ]
  }
}

{:ok, transaction, event} =
  DoubleEntryLedger.EventStore.process_from_event_params(event_params)
```

---

## Summary

- **When creating events, use signed amounts:**  
  - Positive = add to account  
  - Negative = subtract from account
- **Do not specify debit or credit:** The system handles this internally.
- **All events must balance:** The sum of all debits and credits (per currency) must be equal.
- **Account types matter:** To introduce or remove value, use accounts of different types.
- **The ledger enforces integrity:** Any unbalanced event is rejected.
- **You can process events synchronously by calling the event store directly.**

This approach keeps your API simple and intuitive, while the underlying ledger ensures strict double entry accounting rules are always followed.
