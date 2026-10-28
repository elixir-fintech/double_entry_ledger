@wip
Feature: Event sourcing and audit trail
  Commands are the write-ahead log; journal events are the append-only
  business record: the library only ever inserts them, never updates
  them. Every successful command appends exactly one
  journal event linking the command to its transaction or account, and
  every entry mutation appends a balance history row that chains back
  to the original API call.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Creating an account appends a journal event
    Then the ledger instance has 2 journal events
    And each journal event links to the account it created

  Scenario: Creating a transaction appends a journal event
    Given I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    Then the ledger instance has 3 journal events
    And the latest journal event links the command to its transaction

  Scenario: Posting a pending transaction appends another journal event
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I post the pending transaction
    Then the ledger instance has 4 journal events

  Scenario: Later activity leaves earlier journal events untouched
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I note the latest journal event
    When I post the pending transaction
    Then the noted journal event is unchanged

  Scenario: Journal events list newest first
    Given I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    And I create a posted transaction of 50000 EUR between "cash:eur" and "capital:eur"
    When I list the ledger instance's journal events
    Then the events are ordered newest first
    And the first events are the transaction events, latest transaction first
    And the account creations come last

  Scenario: A journal event records the original command
    Given I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    Then the latest journal event carries the command's original payload

  Scenario: Every entry mutation appends a balance history row
    Given I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    Then the account "cash:eur" has 1 balance history entry
    And the account "capital:eur" has 1 balance history entry

  Scenario: A balance history row traces back to the original command
    Given I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"
    Then the latest balance history entry of "cash:eur" links to the transaction's entry
    And that entry links to the transaction
    And that transaction links to its journal event and command

  Scenario: Updating a hold appends pending history
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I update the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    Then the account "cash:eur" has 2 balance history entries

  Scenario: A rejected command writes no journal event
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
    Then the transaction is rejected
    And the ledger instance has 2 journal events

  Scenario: Processing leaves the stored command untouched
    Processing only updates the command's queue item; the command's
    payload and idempotency keys stay as submitted.
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    When the command queue processes the ledger's commands
    Then the command's payload is unchanged from what was submitted
