@wip
Feature: Ledger queries
  Read models are exposed through Flop-backed listings: cursor
  pagination, allow-listed filters, and ordering. Queries are always
  scoped to an instance, an account, or a transaction.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    And I create a pending transaction of 5000 EUR between "cash:eur" and "capital:eur"

  Scenario: Transactions list for an instance
    When I list the transactions of the ledger instance
    Then the listing holds 2 transactions

  Scenario: Transactions list newest first by default
    When I list the transactions of the ledger instance
    Then the first transaction in the listing is the pending transaction

  Scenario: Transactions can be filtered by status
    When I list the transactions of the ledger instance filtered by status posted
    Then the listing holds 1 transaction
    And the transaction in the listing is posted

  Scenario: Transactions paginate by cursor
    Given I create 3 more posted transactions between "cash:eur" and "capital:eur"
    When I list the first 2 transactions of the ledger instance
    Then the listing holds 2 transactions
    And the next page holds 3 transactions

  Scenario: Accounts list for an instance can be filtered by type
    When I list the accounts of the ledger instance filtered by type asset
    Then the listing holds 1 account
    And the account in the listing is "cash:eur"

  Scenario: An account's balance history lists its mutations
    When I list the balance history of "cash:eur"
    Then the listing holds 2 balance history entries
    And the entries are ordered by insertion time

  Scenario: A fresh account has an empty balance history
    Given an asset account "savings:eur" in EUR
    When I list the balance history of "savings:eur"
    Then the listing is empty

  Scenario: Journal events for an account include the transactions touching it
    The account's own lifecycle events and the events of every
    transaction with an entry on the account are both listed.
    When I list the journal events of the account "cash:eur"
    Then the listing holds 3 journal events

  Scenario: Transactions can be listed per account
    When I list the transactions touching the account "cash:eur"
    Then the listing holds 2 transactions

  Scenario: Commands list for an instance
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 1000   | EUR      |
      | capital:eur   | 1000   | EUR      |
    When I list the commands of the ledger instance
    Then the listing holds 1 command

  Scenario: Filtering on a field the query API does not allow is rejected
    When I list the transactions of the ledger instance filtered by an unsupported field
    Then the query is rejected
