Feature: Transaction posting
  A transaction posts equal entries to two accounts. A posted transaction
  settles into each account's posted balance; a pending transaction only
  moves the pending balance and leaves funds unsettled.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And a liability account "loans:eur" in EUR

  Scenario: A posted transaction settles both accounts
    When I create a posted transaction of 100 EUR between "cash:eur" and "loans:eur"
    Then the posted balance of "cash:eur" is 100
    And the posted balance of "loans:eur" is 100
    And the pending balance of "cash:eur" is 0
    And the pending balance of "loans:eur" is 0
    And the available balance of "cash:eur" is 100
    And the available balance of "loans:eur" is 100

  Scenario: A pending transaction holds funds without settling
    When I create a pending transaction of 100 EUR between "cash:eur" and "loans:eur"
    Then the pending balance of "cash:eur" is 100
    And the pending balance of "loans:eur" is 100
    And the posted balance of "cash:eur" is 0
    And the posted balance of "loans:eur" is 0
    And the available balance of "cash:eur" is 0
    And the available balance of "loans:eur" is 0
