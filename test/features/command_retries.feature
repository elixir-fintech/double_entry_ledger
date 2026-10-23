@wip
Feature: Command failures and retries
  The queue distinguishes terminal validation failures from transient
  ones. Validation failures are dead-lettered and never retried;
  optimistic concurrency conflicts are retried automatically; and
  unexpected exceptions are retried with exponential backoff until the
  retry budget is exhausted, after which the command is dead-lettered.
  Every attempt is recorded on the queue item.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: A command with a missing account is dead-lettered without retries
    Given I enqueue a create transaction command from "billing" with idempotency key "bad-1" with entries:
      | account       | amount | currency |
      | ghost:eur     | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    When the command queue processes the ledger's commands
    Then the command's queue item status is dead_letter
    And the queue item records the failure
    And the command was retried 0 times

  Scenario: A command with unbalanced entries is dead-lettered without retries
    Given I enqueue a create transaction command from "billing" with idempotency key "bad-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
    When the command queue processes the ledger's commands
    Then the command's queue item status is dead_letter
    And the queue item records the failure

  Scenario: An unexpected exception is scheduled for retry with backoff
    Given an enqueued command whose processing raises an unexpected exception
    When the command queue processes the ledger's commands
    Then the command's queue item status is failed
    And the queue item has a retry scheduled
    And a "command retry" telemetry event is emitted

  Scenario: An optimistic concurrency conflict is marked occ_timeout and retried
    Given an enqueued command that hits an optimistic concurrency conflict
    When the command queue processes the ledger's commands
    Then the command's queue item status is occ_timeout
    And the queue item has a retry scheduled

  Scenario: A retried command eventually succeeds
    Given an enqueued command that fails once with an unexpected exception
    When the command queue processes the ledger's commands
    And the retry becomes due
    And the command queue processes the ledger's commands
    Then the command's queue item status is processed
    And the posted balance of "cash:eur" is 100000

  Scenario: A scheduled retry is not claimable before its deadline
    Retry eligibility is judged on the database clock: a command whose
    next retry is in the future stays put.
    Given a failed command whose retry deadline is still in the future
    When the command queue processes the ledger's commands
    Then the command's queue item status is failed
    And the command was not claimed

  Scenario: A command is dead-lettered after exhausting its retries
    Given an enqueued command that always fails with an unexpected exception
    When the command queue processes the ledger's commands exhaustively
    Then the command's queue item status is dead_letter
    And the queue item records the failure
    And a "command dead letter" telemetry event is emitted

  Scenario: A failed command leaves no partial projections
    Given I enqueue a create transaction command from "billing" with idempotency key "bad-3" with entries:
      | account       | amount | currency |
      | ghost:eur     | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    When the command queue processes the ledger's commands
    Then the ledger instance has 0 transactions
    And the posted balance of "capital:eur" is 0

  Scenario: A crashed worker task is retried automatically
    Worker tasks are monitored; an in-process crash schedules a retry
    for the command without manual intervention.
    Given an enqueued command whose worker task crashes
    When the command queue processes the ledger's commands
    Then the command has a retry scheduled
    And the command's queue item was not marked processed
