@wip
Feature: Signed amount translation
  Callers submit signed amounts rather than debits and credits: a
  positive amount adds value to the account, a negative amount removes
  it. The ledger derives the correct debit or credit from the account's
  type, so callers never specify entry directions themselves.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Injecting capital with two positive amounts
    Positive amounts on an asset and an equity account both increase
    their balances: the ledger records a debit on the asset and a
    credit on the equity.
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    Then the posted balance of "cash:eur" is 100000
    And the posted balance of "capital:eur" is 100000

  Scenario: Moving value between two asset accounts
    A negative amount on one asset account and a matching positive
    amount on another transfer value without creating it: the ledger
    records a credit on the first and a debit on the second.
    Given I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    And an asset account "savings:eur" in EUR
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -50000 | EUR      |
      | savings:eur   | 50000  | EUR      |
    Then the posted balance of "cash:eur" is 50000
    And the posted balance of "savings:eur" is 50000

  Scenario: Decreasing an equity account with a negative amount
    Given I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -30000 | EUR      |
      | capital:eur   | -30000 | EUR      |
    Then the posted balance of "cash:eur" is 70000
    And the posted balance of "capital:eur" is 70000

  Scenario: A sale recorded across three accounts
    A transaction may touch more than two accounts as long as its
    debits and credits are equal.
    Given a revenue account "sales:eur" in EUR
    And a liability account "tax:eur" in EUR
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | sales:eur     | 80000  | EUR      |
      | tax:eur       | 20000  | EUR      |
    Then the posted balance of "cash:eur" is 100000
    And the posted balance of "sales:eur" is 80000
    And the posted balance of "tax:eur" is 20000

  Scenario: Both accounts of a two-sided transfer move by the same magnitude
    Given I create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    When I create a posted transaction of 25000 EUR between "cash:eur" and "capital:eur"
    Then the posted balance of "cash:eur" is 125000
    And the posted balance of "capital:eur" is 125000
