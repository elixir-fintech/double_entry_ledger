@wip
Feature: Available balances
  The available balance is the real calculated balance: posted amount
  minus the pending amount on the opposite side of the account's normal
  balance. Pending balances are direction-aware like posted ones, so a
  pending entry against the account's normal direction shows as a
  negative pending balance. A pending entry that moves in the account's
  normal direction is an expected inflow and does not change
  availability; a pending entry on the opposite side is an expected
  outflow and lowers it. The negative limit bounds how far below zero
  availability may go.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"

  Scenario: A pending debit on a debit-normal account does not change availability
    An asset account expects pending debits as future inflows, which
    are not guaranteed until posting.
    When I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 30000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    Then the pending balance of "cash:eur" is 30000
    And the available balance of "cash:eur" is 100000

  Scenario: A pending credit on a debit-normal account lowers availability
    When I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -30000 | EUR      |
      | capital:eur   | -30000 | EUR      |
    Then the pending balance of "cash:eur" is -30000
    And the available balance of "cash:eur" is 70000

  Scenario: A pending credit on a credit-normal account does not change availability
    A liability or equity account expects pending credits as future
    increases, which are not guaranteed until posting.
    When I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 30000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    Then the pending balance of "capital:eur" is 30000
    And the available balance of "capital:eur" is 100000

  Scenario: A pending debit on a credit-normal account lowers availability
    When I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -30000 | EUR      |
      | capital:eur   | -30000 | EUR      |
    Then the available balance of "capital:eur" is 70000

  Scenario: Posting the hold converts reserved funds into posted balance
    Given I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -30000 | EUR      |
      | capital:eur   | -30000 | EUR      |
    When I post the pending transaction
    Then the pending balance of "cash:eur" is 0
    And the available balance of "cash:eur" is 70000
    And the posted balance of "cash:eur" is 70000

  Scenario: Archiving the hold releases the reserved funds
    Given I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -30000 | EUR      |
      | capital:eur   | -30000 | EUR      |
    When I archive the pending transaction
    Then the pending balance of "cash:eur" is 0
    And the available balance of "cash:eur" is 100000
    And the posted balance of "cash:eur" is 100000

  Scenario: With the default limit, availability cannot go below zero
    Given an asset account "strict:eur" in EUR with negative limit 0
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | strict:eur    | -10000 | EUR      |
      | cash:eur      | 10000  | EUR      |
    Then the transaction is rejected with an error containing "negative"

  Scenario: A negative limit allows availability to fall to its bound
    Given an asset account "overdraft:eur" in EUR with negative limit 50000
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | overdraft:eur | -50000 | EUR      |
      | cash:eur      | 50000  | EUR      |
    Then the available balance of "overdraft:eur" is -50000

  Scenario: A negative limit rejects availability beyond its bound
    Given an asset account "overdraft:eur" in EUR with negative limit 50000
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | overdraft:eur | -50001 | EUR      |
      | cash:eur      | 50001  | EUR      |
    Then the transaction is rejected with an error containing "negative"

  Scenario: A pending hold can consume availability down to the limit
    Given an asset account "overdraft:eur" in EUR with negative limit 50000
    When I create a pending transaction with entries:
      | account       | amount | currency |
      | overdraft:eur | -50000 | EUR      |
      | cash:eur      | 50000  | EUR      |
    Then the available balance of "overdraft:eur" is -50000
    And the posted balance of "overdraft:eur" is 0
