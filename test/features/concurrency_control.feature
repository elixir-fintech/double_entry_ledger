@wip
Feature: Optimistic concurrency control
  Account rows carry a lock version. Writers must present the version
  they read; when a competing write has advanced it, the stale writer
  fails with a stale entry error and retries, so concurrent
  transactions on the same account serialize without losing either
  one.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Concurrent posted transactions on one account both apply
    Two transactions race for the same account; the OCC retry loop
    serializes them and neither is lost.
    When I concurrently create 2 posted transactions of 10000 EUR between "cash:eur" and "capital:eur"
    Then the posted balance of "cash:eur" is 20000
    And the posted balance of "capital:eur" is 20000

  Scenario: Each mutation advances the account's lock version
    When I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    Then the account "cash:eur" has lock version 2
    When I create a posted transaction of 5000 EUR between "cash:eur" and "capital:eur"
    Then the account "cash:eur" has lock version 3

  Scenario: A stale write is rejected rather than applied
    Given the account "cash:eur" at lock version 1
    When I write a balance change for "cash:eur" presenting lock version 1 after the row advanced
    Then the write fails with a stale entry error

  Scenario: An OCC conflict is retried within the same command
    Given a command that hits an optimistic concurrency conflict on its first attempt
    When I process the command
    Then an "occ retry" telemetry event is emitted
    And the command's queue item status is processed

  Scenario: Exhausted OCC retries mark the command occ_timeout
    The command is not lost: it is scheduled for another queue round.
    Given a command that exhausts its OCC retries
    When I process the command
    Then the command's queue item status is occ_timeout
    And the queue item records the OCC exhaustion
    And the queue item has a retry scheduled

  Scenario: Concurrent duplicate commands process exactly once
    Two commands carrying the same source and idempotency key race;
    the idempotency constraint lets only one through.
    When I concurrently enqueue 2 create transaction commands from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    And the command queue processes the ledger's commands
    Then exactly one of the commands is processed
    And the posted balance of "cash:eur" is 10000

  Scenario: With serialized enqueue, queue positions follow commit order
    Without it, positions come from a sequence, and two concurrent
    enqueues can commit in the opposite order to their positions.
    Given serialized enqueue is enabled
    When an enqueue for the ledger is held open inside an outer transaction
    And a second enqueue for the ledger starts
    Then the second enqueue waits until the first commits
    And the first command has the lower queue position
