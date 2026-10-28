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

  # --- Holds against available funds ---------------------------------
  # The counter entries below go to an expense account: a pending debit
  # on a debit-normal account does not lower its availability, so only
  # "cash:eur" is checked against its limit.

  Scenario: A hold larger than the available balance is rejected
    This is a declined authorization: there are not enough funds to
    reserve.
    Given an expense account "purchases:eur" in EUR
    When I attempt to create a pending transaction with entries:
      | account       | amount  | currency |
      | cash:eur      | -100001 | EUR      |
      | purchases:eur | 100001  | EUR      |
    Then the transaction is rejected with an error containing "negative"
    And the pending balance of "cash:eur" is 0
    And the available balance of "cash:eur" is 100000

  Scenario: A hold for exactly the available balance is accepted
    Given an expense account "purchases:eur" in EUR
    When I create a pending transaction with entries:
      | account       | amount  | currency |
      | cash:eur      | -100000 | EUR      |
      | purchases:eur | 100000  | EUR      |
    Then the available balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 100000

  # --- Spending the same funds twice ---------------------------------

  Scenario: A second hold cannot reserve funds the first hold already reserved
    Given an expense account "purchases:eur" in EUR
    And I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -60000 | EUR      |
      | purchases:eur | 60000  | EUR      |
    When I attempt to create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -50000 | EUR      |
      | purchases:eur | 50000  | EUR      |
    Then the transaction is rejected with an error containing "negative"
    And the pending balance of "cash:eur" is -60000
    And the available balance of "cash:eur" is 40000

  Scenario: A posted payment cannot spend funds a hold has reserved
    Given an expense account "purchases:eur" in EUR
    And I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -60000 | EUR      |
      | purchases:eur | 60000  | EUR      |
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -50000 | EUR      |
      | purchases:eur | 50000  | EUR      |
    Then the transaction is rejected with an error containing "negative"
    And the posted balance of "cash:eur" is 100000
    And the available balance of "cash:eur" is 40000

  Scenario: Concurrent holds cannot together overspend
    Each hold fits on its own but not both together. Optimistic
    concurrency serializes them, so the loser re-reads the account,
    sees the winner's reservation, and fails the limit check.
    Given an expense account "purchases:eur" in EUR
    When I concurrently create 2 pending transactions with entries:
      | account       | amount | currency |
      | cash:eur      | -60000 | EUR      |
      | purchases:eur | 60000  | EUR      |
    Then exactly one of the transactions is accepted
    And the other transaction is rejected with an error containing "negative"
    And the pending balance of "cash:eur" is -60000
    And the available balance of "cash:eur" is 40000

  # --- Growing a hold past the limit ---------------------------------

  Scenario: Raising a hold beyond the available balance is rejected
    Given an expense account "purchases:eur" in EUR
    And I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -60000 | EUR      |
      | purchases:eur | 60000  | EUR      |
    When I attempt to update the pending transaction with entries:
      | account       | amount  | currency |
      | cash:eur      | -100001 | EUR      |
      | purchases:eur | 100001  | EUR      |
    Then the update is rejected with an error containing "negative"
    And the pending balance of "cash:eur" is -60000
    And the available balance of "cash:eur" is 40000

  Scenario: Posting a hold for more than the available balance is rejected
    Amending the amount at capture is checked against the limit like
    any other write.
    Given an expense account "purchases:eur" in EUR
    And I create a pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -60000 | EUR      |
      | purchases:eur | 60000  | EUR      |
    When I attempt to post the pending transaction with entries:
      | account       | amount  | currency |
      | cash:eur      | -100001 | EUR      |
      | purchases:eur | 100001  | EUR      |
    Then the update is rejected with an error containing "negative"
    And the pending balance of "cash:eur" is -60000
    And the posted balance of "cash:eur" is 100000

  # --- Limits on credit-normal accounts ------------------------------
  # A liability's availability falls when it is debited, so a customer
  # deposit account cannot be drawn below zero without a limit.

  Scenario: With the default limit, a credit-normal account cannot go below zero
    Given a liability account "deposits:eur" in EUR with negative limit 0
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | deposits:eur  | -10000 | EUR      |
      | cash:eur      | -10000 | EUR      |
    Then the transaction is rejected with an error containing "negative"
    And the posted balance of "deposits:eur" is 0

  Scenario: A negative limit lets a credit-normal account fall to its bound
    Given a liability account "deposits:eur" in EUR with negative limit 50000
    When I create a posted transaction with entries:
      | account       | amount | currency |
      | deposits:eur  | -50000 | EUR      |
      | cash:eur      | -50000 | EUR      |
    Then the available balance of "deposits:eur" is -50000

  Scenario: A negative limit rejects a credit-normal account beyond its bound
    Given a liability account "deposits:eur" in EUR with negative limit 50000
    When I attempt to create a posted transaction with entries:
      | account       | amount | currency |
      | deposits:eur  | -50001 | EUR      |
      | cash:eur      | -50001 | EUR      |
    Then the transaction is rejected with an error containing "negative"
    And the posted balance of "deposits:eur" is 0

  Scenario: A hold cannot draw a credit-normal account below its limit
    Given a liability account "deposits:eur" in EUR with negative limit 0
    When I attempt to create a pending transaction with entries:
      | account       | amount | currency |
      | deposits:eur  | -10000 | EUR      |
      | cash:eur      | -10000 | EUR      |
    Then the transaction is rejected with an error containing "negative"
    And the pending balance of "deposits:eur" is 0
