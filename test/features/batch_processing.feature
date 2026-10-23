@wip
Feature: Batch processing
  With batching enabled, compatible transaction commands are claimed
  and written together in one database transaction. Account commands
  always go through the single-command path, and a batch that hits an
  unexpected database error falls back to processing its commands one
  at a time.

  Background:
    Given a ledger instance with batching enabled
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Compatible transaction commands are written as one batch
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    And I enqueue a create transaction command from "billing" with idempotency key "pay-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 20000  | EUR      |
      | capital:eur   | 20000  | EUR      |
    When the command queue processes the ledger's commands
    Then the command's queue item status is processed
    And the posted balance of "cash:eur" is 30000
    And a "batch processed" telemetry event is emitted for 2 commands

  Scenario: A batch is capped at the configured batch size
    Given the batch size is 2
    And I enqueue 3 create transaction commands from "billing"
    When the command queue processes the ledger's commands
    Then all 3 commands are processed

  Scenario: Account commands are never batched
    Given I enqueue a create account command from "back-office" with payload:
      | field     | value      |
      | address   | fees:eur   |
      | type      | expense    |
      | currency  | EUR        |
    And I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    When the command queue processes the ledger's commands
    Then the account "fees:eur" exists
    And the posted balance of "cash:eur" is 10000

  Scenario: An update whose create is in the same batch waits for the next round
    Given I enqueue a create transaction command from "checkout" with idempotency key "hold-1" with payload status pending with entries:
      | account       | amount | currency |
      | cash:eur      | 20000  | EUR      |
      | capital:eur   | 20000  | EUR      |
    And I enqueue an update transaction command from "checkout" with idempotency key "hold-1" and update idempotency key "hold-1-post" to posted
    When the command queue processes the ledger's commands
    Then the pending balance of "cash:eur" is 20000
    When the command queue processes the ledger's commands
    Then the pending balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 20000

  Scenario: Duplicate updates in one batch are deferred, not lost
    Given I enqueue a create transaction command from "checkout" with idempotency key "hold-1" with payload status pending with entries:
      | account       | amount | currency |
      | cash:eur      | 20000  | EUR      |
      | capital:eur   | 20000  | EUR      |
    And the command queue processes the ledger's commands
    And I enqueue an update transaction command from "checkout" with idempotency key "hold-1" and update idempotency key "adj-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    And I enqueue an update transaction command from "checkout" with idempotency key "hold-1" and update idempotency key "adj-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 30000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    When the command queue processes the ledger's commands
    Then the pending balance of "cash:eur" is 25000
    When the command queue processes the ledger's commands
    Then the pending balance of "cash:eur" is 30000

  Scenario: A batch failure falls back to single-command processing
    Given a batch of compatible commands that hits an unexpected database error
    When the command queue processes the ledger's commands
    Then the commands are processed one at a time
    And every command reaches a terminal queue item status

  Scenario: A batch of unbalanced commands records each failure
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 9000   | EUR      |
    And I enqueue a create transaction command from "billing" with idempotency key "pay-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 20000  | EUR      |
      | capital:eur   | 20000  | EUR      |
    When the command queue processes the ledger's commands
    Then the command with idempotency key "pay-1" is dead-lettered
    And the command with idempotency key "pay-2" is processed
    And the posted balance of "cash:eur" is 20000

  Scenario: Batching can be switched on without restarting
    Given batching is switched on at runtime
    And I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    When the command queue processes the ledger's commands
    Then the command's queue item status is processed
