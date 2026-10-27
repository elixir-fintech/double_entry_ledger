@wip
Feature: Pending transaction lifecycle
  Pending transactions model holds and authorizations. They move
  pending balances on creation, can be edited while pending, and must
  eventually be posted (finalized) or archived (canceled). Posted and
  archived transactions are immutable.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I create a posted transaction of 100000 EUR between "cash:eur" and "capital:eur"

  Scenario: Creating a hold reserves pending balances
    When I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    Then a pending transaction exists
    And the pending balance of "cash:eur" is 20000
    And the pending balance of "capital:eur" is 20000
    And the posted balance of "cash:eur" is 100000

  Scenario: Editing the amounts of a hold while it is pending
    Updates reference the original source and source idempotency key
    and supply their own update idempotency key. Account addresses,
    currencies, and entry count must match the original; only the
    signed amounts may change, each entry must keep its direction, and
    the transaction must stay balanced.
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I update the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    Then the pending balance of "cash:eur" is 25000
    And the posted balance of "cash:eur" is 100000

  Scenario: An edit that flips an entry's direction is rejected
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I attempt to update the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | -25000 | EUR      |
      | capital:eur   | -25000 | EUR      |
    Then the update is rejected with an error containing "sign"
    And the pending balance of "cash:eur" is 20000


  Scenario: An edit that changes the accounts of a hold is rejected
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And an asset account "savings:eur" in EUR
    When I attempt to update the pending transaction with entries:
      | account       | amount | currency |
      | savings:eur   | 20000  | EUR      |
      | capital:eur   | 20000  | EUR      |
    Then the update is rejected
    And the pending balance of "cash:eur" is 20000

  Scenario: An edit that unbalances the hold is rejected
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I attempt to update the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 20000  | EUR      |
      | capital:eur   | 30000  | EUR      |
    Then the update is rejected with an error containing "equal debit and credit"

  Scenario: Posting a hold finalizes it into posted balances
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I post the pending transaction
    Then the pending balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 120000
    And the posted balance of "capital:eur" is 120000

  Scenario: Archiving a hold releases its reservation
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I archive the pending transaction
    Then the pending balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 100000
    And the transaction status is archived

  Scenario: A transaction cannot be created directly in the archived state
    When I attempt to create an archived transaction of 20000 EUR between "cash:eur" and "capital:eur"
    Then the transaction is rejected with an error containing "archived"

  Scenario: A posted transaction cannot be updated
    Given I create a posted transaction of 5000 EUR between "cash:eur" and "capital:eur"
    When I attempt to post that transaction again
    Then the update is rejected with an error containing "posted"

  Scenario: An archived transaction cannot be updated
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I archive the pending transaction
    When I attempt to post the archived transaction
    Then the update is rejected with an error containing "archived"

  Scenario: An edit that changes the number of entries is rejected
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And an asset account "savings:eur" in EUR
    When I attempt to update the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 20000  | EUR      |
      | savings:eur   | 10000  | EUR      |
    Then the update is rejected with an error containing "number of entries"

  Scenario: An update must reference the original source and idempotency key
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I attempt to post the pending transaction from a different source
    Then the update command is dead-lettered

  Scenario: An update whose create command has not run yet waits for it
    The update is returned to the queue instead of failing, and is
    processed once the create command completes.
    Given an update command enqueued before its create command completes
    When the create command completes successfully
    And the command queue processes the ledger's commands
    Then the update command is processed

  Scenario: An update whose create command dead-lettered is dead-lettered too
    Given a create command that dead-letters
    And an update command for it
    When the command queue processes the ledger's commands
    Then the update command is dead-lettered

  Scenario: An update whose create command does not exist is dead-lettered
    When I enqueue an update transaction command from "checkout" with idempotency key "order-never" and update idempotency key "post-1" to posted
    And the command queue processes the ledger's commands
    Then the update command is dead-lettered


  Scenario: A hold records its own journal events through its lifecycle
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    And I post the pending transaction
    Then a "transaction created" journal event exists for that transaction
    And a "transaction posted" journal event exists for that transaction

  Scenario: Posting a hold with amended amounts
    A hold can be finalized for a different amount than it reserved,
    such as a tip added at capture. The amounts follow the same rules
    as an edit.
    Given I create a pending transaction of 20000 EUR between "cash:eur" and "capital:eur"
    When I post the pending transaction with entries:
      | account       | amount | currency |
      | cash:eur      | 25000  | EUR      |
      | capital:eur   | 25000  | EUR      |
    Then the pending balance of "cash:eur" is 0
    And the posted balance of "cash:eur" is 125000
