@wip
Feature: Balanced transactions
  Every transaction must balance: the sum of its debits equals the sum
  of its credits, per currency. Entries must reference existing
  accounts on the same ledger instance, and each entry's currency must
  match its account's currency. Unbalanced or malformed transactions
  are rejected.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: An unbalanced transaction is rejected
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
    Then the transaction is rejected with an error containing "equal debit and credit"
    And the posted balance of "cash:eur" is 0

  Scenario: A transaction with a single entry is rejected
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
    Then the transaction is rejected with an error containing "at least 2 entries"

  Scenario: A transaction with no entries is rejected
    When I attempt to create a posted transaction with entries:
      | account | amount | currency |
    Then the transaction is rejected with an error containing "at least 2 entries"

  Scenario: A transaction referencing an unknown account is rejected
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | ghost:eur     | 100000 | EUR      |
    Then the transaction is rejected

  Scenario: Each currency must balance on its own
    A transaction spanning several currencies is only valid when the
    debits and credits of every currency are equal.
    Given an asset account "cash:usd" in USD
    And an equity account "capital:usd" in USD
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
      | cash:usd      | 50000  | USD      |
      | capital:usd   | 50000  | USD      |
    Then the transaction is rejected with an error containing "equal debit and credit"
    And the posted balance of "cash:usd" is 0

  Scenario: A multi-currency transaction balanced per currency is accepted
    Given an asset account "cash:usd" in USD
    And an equity account "capital:usd" in USD
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
      | cash:usd      | 50000  | USD      |
      | capital:usd   | 50000  | USD      |
    Then the posted balance of "cash:eur" is 100000
    And the posted balance of "cash:usd" is 50000

  Scenario: An entry whose currency differs from its account's currency is rejected
    Given an asset account "cash:usd" in USD
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
      | cash:usd      | 50000  | EUR      |
    Then the transaction is rejected

  Scenario: An account from another ledger instance cannot be referenced
    Account addresses resolve within the transaction's own instance, so
    an account that lives in a different instance is simply not found.
    Given a second ledger instance
    And an equity account "other:capital:eur" in EUR
    When I attempt to create a posted transaction in the first ledger instance with entries:
      | account           | amount | currency |
      | cash:eur          | 100000 | EUR      |
      | other:capital:eur | 100000 | EUR      |
    Then the transaction is rejected with an error containing "some_accounts_not_found"
    And the posted balance of "cash:eur" in the first ledger instance is 0

  Scenario: A transaction cannot repeat an account
    Each entry must name a distinct account.
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | cash:eur      | -100000 | EUR     |
    Then the transaction is rejected with an error containing "distinct"

  Scenario: A rejected transaction leaves no trace in the ledger
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
    Then the transaction is rejected
    And the ledger instance has 0 transactions
    And the ledger instance has 2 journal events
