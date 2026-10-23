@wip
Feature: Instance lifecycle
  A ledger instance is the isolation boundary for accounts,
  transactions, and commands. Instances are created with a unique
  address, can be described and configured, and their books can be
  validated for balance.

  Scenario: Creating a ledger instance
    Given no ledger instance exists
    When I create a ledger instance "acme:ledger" described as "Internal ledger for ACME Corp"
    Then the instance "acme:ledger" exists
    And its description is "Internal ledger for ACME Corp"

  Scenario: Instance addresses are unique
    Given a ledger instance "acme:ledger"
    When I create a ledger instance "acme:ledger"
    Then the instance creation is rejected

  Scenario: A ledger instance is required to have an address
    When I create a ledger instance without an address
    Then the instance creation is rejected

  Scenario: An instance address must match the addressing format
    When I create a ledger instance "acme ledger!"
    Then the instance creation is rejected

  Scenario: An instance with accounts cannot be deleted
    Given a ledger instance "acme:ledger"
    And an asset account "cash:eur" in EUR
    When I delete the instance "acme:ledger"
    Then the instance deletion is rejected
    And the instance "acme:ledger" still exists

  Scenario: An instance with transactions cannot be deleted
    Given a ledger instance "acme:ledger"
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    When I delete the instance "acme:ledger"
    Then the instance deletion is rejected


  Scenario: Updating an instance description
    Given a ledger instance "acme:ledger" described as "before"
    When I update the instance "acme:ledger" description to "after"
    Then its description is "after"

  Scenario: Deleting an instance without recorded data
    Given a ledger instance "acme:ledger"
    When I delete the instance "acme:ledger"
    Then the instance "acme:ledger" no longer exists

  Scenario: Validating that an instance's books balance
    Every posted and pending projection must keep debits equal to
    credits per currency across the instance's accounts.
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR
    And I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    When I validate the balances of the ledger instance
    Then validation succeeds

  Scenario: An instance with no accounts validates successfully
    Given a ledger instance
    When I validate the balances of the ledger instance
    Then validation succeeds
