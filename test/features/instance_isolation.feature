@wip
Feature: Instance isolation
  Every instance owns its accounts, transactions, commands, and
  idempotency keys. Identical addresses in different instances are
  different accounts, and no query leaks one tenant's data into
  another's results.

  Background:
    Given a ledger instance "acme:ledger"
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    And a second ledger instance "globex:ledger"
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: The same account address can exist in two instances
    Then the account "cash:eur" exists in instance "acme:ledger"
    And the account "cash:eur" exists in instance "globex:ledger"
    And the instances' accounts are distinct records

  Scenario: An account address resolves only within its own instance
    When I look up the account "cash:eur" in instance "globex:ledger"
    Then I find an account belonging to "globex:ledger"

  Scenario: Listing accounts is scoped to one instance
    When I list the accounts of instance "acme:ledger"
    Then the listing holds 2 accounts
    And every account belongs to "acme:ledger"

  Scenario: An unknown instance address yields an empty listing, not an error
    When I list the accounts of instance "ghost:ledger"
    Then the listing is empty

  Scenario: Transactions are scoped to one instance
    When I list the transactions of instance "globex:ledger"
    Then the listing is empty
    When I list the transactions of instance "acme:ledger"
    Then the listing holds 1 transaction

  Scenario: Journal events are scoped to one instance
    When I list the journal events of instance "globex:ledger"
    Then the listing holds 2 journal events
    When I list the journal events of instance "acme:ledger"
    Then the listing holds 3 journal events

  Scenario: Idempotency keys are scoped per instance
    The same source and idempotency key can be used independently in
    two different instances.
    When I enqueue a create transaction command for instance "acme:ledger" from "checkout" with idempotency key "order-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    And I enqueue a create transaction command for instance "globex:ledger" from "checkout" with idempotency key "order-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 5000   | EUR      |
      | capital:eur   | 5000   | EUR      |
    Then both commands are stored

  Scenario: Processing one instance's queue leaves the other untouched
    Given I enqueue a create transaction command for instance "globex:ledger" from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 5000   | EUR      |
      | capital:eur   | 5000   | EUR      |
    When the command queue processes the commands of instance "globex:ledger"
    Then the posted balance of "cash:eur" in instance "globex:ledger" is 5000
    And the posted balance of "cash:eur" in instance "acme:ledger" is 10000
