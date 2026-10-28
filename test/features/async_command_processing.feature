@wip
Feature: Asynchronous command processing
  Commands submitted for asynchronous processing are stored durably
  with a pending queue item and returned immediately. The command
  queue discovers the work, claims it under the ledger's lease, runs
  the worker, and records the outcome on the queue item. Projections
  appear only once processing succeeds.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |

  Scenario: An enqueued command starts out pending with no projections
    Then the command is stored with queue item status pending
    And the ledger instance has 0 transactions
    And the posted balance of "cash:eur" is 0

  Scenario: The queue processes an enqueued command
    When the command queue processes the ledger's commands
    Then the command's queue item status is processed
    And a posted transaction exists
    And the posted balance of "cash:eur" is 100000
    And the posted balance of "capital:eur" is 100000

  Scenario: Processing records a journal event for the command
    When the command queue processes the ledger's commands
    Then the ledger instance has 3 journal events
    And the journal event links the command to its transaction

  Scenario: A queued pending transaction reserves funds once processed
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-2" with payload status pending with entries:
      | account       | amount | currency |
      | cash:eur      | 30000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    When the command queue processes the ledger's commands
    Then the command's queue item status is processed
    And the pending balance of "cash:eur" is 30000
    And the posted balance of "cash:eur" is 100000

  Scenario: A queued update command finalizes its transaction
    Given I enqueue a create transaction command from "checkout" with idempotency key "hold-1" with payload status pending with entries:
      | account       | amount | currency |
      | cash:eur      | -20000 | EUR      |
      | capital:eur   | -20000 | EUR      |
    And the command queue processes the ledger's commands
    When I enqueue an update transaction command from "checkout" with idempotency key "hold-1" and update idempotency key "hold-1-post" to posted
    And the command queue processes the ledger's commands
    Then the pending balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 80000

  Scenario: Commands for a ledger are processed in queue order
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    When the command queue processes the ledger's commands
    Then the commands are processed in queue position order

  Scenario: The enqueued command can be inspected through the command store
    When the command queue processes the ledger's commands
    Then the command store lists the command for the instance
    And the command store returns the command with its queue item

  Scenario: Only processed commands produce visible projections
    When the command queue is idle
    Then the ledger instance has 0 transactions
    When the command queue processes the ledger's commands
    Then the ledger instance has 1 transaction

  Scenario: A queued account update changes the account
    Given I enqueue an update account command from "back-office" for "cash:eur" with description "Operating cash"
    When the command queue processes the ledger's commands
    Then the account "cash:eur" has description "Operating cash"

  Scenario: A queued update command archives its transaction
    Given I enqueue a create transaction command from "checkout" with idempotency key "hold-1" with payload status pending with entries:
      | account       | amount | currency |
      | cash:eur      | -20000 | EUR      |
      | capital:eur   | -20000 | EUR      |
    And the command queue processes the ledger's commands
    When I enqueue an update transaction command from "checkout" with idempotency key "hold-1" and update idempotency key "hold-1-void" to archived
    And the command queue processes the ledger's commands
    Then the pending balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 100000
    And the transaction status is archived
