@wip
Feature: Ledger lease ownership
  Each ledger has one lease row in PostgreSQL. The lease owner is the
  only writer allowed to claim or complete that ledger's queued
  commands: every queue write takes the lease row lock, proves its
  owner id and fencing token still hold, and refreshes the expiry. A
  dead owner's lease expires and is taken over, and the takeover
  reschedules whatever the dead owner left in flight.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Acquiring a ledger lease
    When a node acquires the ledger lease
    Then the lease is granted
    And a "lease acquired" telemetry event is emitted

  Scenario: Only one node works a ledger at a time
    When a node acquires the ledger lease
    And another node tries to acquire the same lease
    Then the second node does not get the lease
    And the first node still holds the lease

  Scenario: A released lease can be acquired again
    When a node acquires the ledger lease
    And the node releases the lease
    And another node acquires the ledger lease
    Then the lease is granted
    And the fencing token was incremented

  Scenario: An expired lease is taken over by another node
    When a node acquires the ledger lease
    And the node dies without releasing the lease
    And the lease expires
    And another node acquires the same lease
    Then the lease is granted
    And a "lease acquired" telemetry event is emitted with takeover true

  Scenario: Commands left processing by a dead owner are rescheduled
    Given an enqueued command that a dead node left in the processing state
    When another node acquires the lease
    Then the orphaned command is rescheduled
    And a "command recovered" telemetry event is emitted with reason "takeover"

  Scenario: A stale owner cannot overwrite its successor
    Fencing proves ownership on every write: an owner whose lease has
    been taken over fails its writes rather than corrupting the
    successor's work.
    Given a command claimed by a node that has lost its lease
    When the stale node tries to complete the command
    Then the write is fenced out
    And the command's queue item is untouched by the stale node

  Scenario: A processor that lost its lease stops without writing
    Given a processor working under a lease that has been taken over
    When the processor notices the loss
    Then a "lease lost" telemetry event is emitted
    And the processor writes nothing further

  Scenario: A drained ledger releases its lease
    Given an enqueued create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    And a node acquires the ledger lease
    When the command queue processes the ledger's commands
    Then the command's queue item status is processed
    And the lease is released with reason "drained"

  Scenario: Lease contention is reported rather than blocking
    A writer waits for the lease row lock only up to the configured
    lock timeout, then reports contention instead of blocking.
    Given a transaction holding the lease row lock
    When a node tries to acquire the lease
    Then the acquisition reports contention

  Scenario: The lease covers queued commands only
    Synchronous processing takes no lease: it runs on the calling node
    and is serialized against the queue owner only by account-level
    optimistic concurrency control.
    Given a node holds the ledger lease
    When I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    Then the posted balance of "cash:eur" is 100000
    And the node still holds the lease
