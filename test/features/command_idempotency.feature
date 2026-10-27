@wip
Feature: Command idempotency
  Every command is keyed by its instance, source, and source idempotency
  key; updates add their own update idempotency key. The hash of these
  keys prevents duplicate processing, and the pending transaction
  lookup ties updates to the transaction created by the original
  pending command.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Enqueuing the same create command twice is rejected while the first is pending
    When I enqueue a create transaction command from "checkout" with idempotency key "order-1" with payload status pending with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    And I enqueue the same command again
    Then the duplicate is rejected with reason "pending_transaction_idempotency_violation"
    And 1 command is stored

  Scenario: A duplicate create is detected as an idempotency hit
    When I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    And I create the same transaction again
    Then an "idempotency hit" telemetry event is emitted
    And the posted balance of "cash:eur" is 100000

  Scenario: The same idempotency key from a different source is accepted
    When I enqueue a create transaction command from "checkout" with idempotency key "order-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    And I enqueue a create transaction command from "back-office" with idempotency key "order-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 50000  | EUR      |
      | capital:eur   | 50000  | EUR      |
    Then 2 commands are stored

  Scenario: The same source with a different idempotency key is accepted
    When I enqueue a create transaction command from "checkout" with idempotency key "order-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    And I enqueue a create transaction command from "checkout" with idempotency key "order-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 50000  | EUR      |
      | capital:eur   | 50000  | EUR      |
    Then 2 commands are stored

  Scenario: A hold registers itself in the pending transaction lookup
    When I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    Then the pending transaction lookup holds the transaction

  Scenario: Posting a hold removes it from the pending transaction lookup
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I post the pending transaction
    Then the pending transaction lookup no longer holds the transaction

  Scenario: Editing a hold keeps it in the pending transaction lookup
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I update the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    Then the pending transaction lookup holds the transaction

  Scenario: Multiple updates with distinct update idempotency keys are allowed
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I update the pending transaction with update idempotency key "adj-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    And I update the pending transaction with update idempotency key "adj-2" with entries:
      | account       | amount | currency |
      | cash:eur      | 30000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    Then the pending balance of "cash:eur" is 30000

  Scenario: Reusing an update idempotency key is rejected
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I update the pending transaction with update idempotency key "adj-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    When I attempt to update the pending transaction with update idempotency key "adj-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 30000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    Then the update is rejected with an error containing "idempotency violation"
    And the pending balance of "cash:eur" is 25000
