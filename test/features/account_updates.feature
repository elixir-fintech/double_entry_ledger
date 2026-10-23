@wip
Feature: Account updates and deletion
  Accounts can have their descriptive fields updated, but their
  identity — address, type, currency, normal balance — is fixed at
  creation. An account that has ever taken part in a transaction can
  never be deleted; an untouched account can.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR

  Scenario: Updating an account's description
    When I update the account "cash:eur" description to "Operating cash"
    Then the account "cash:eur" has description "Operating cash"
    And an "account updated" telemetry event is emitted

  Scenario: Updating an account's name and context
    When I update the account "cash:eur" name to "Cash" and context to a map
    Then the account "cash:eur" has name "Cash"

  Scenario: An account's address is immutable
    When I attempt to update the account "cash:eur" address to "gold:eur"
    Then the account update is rejected
    And the account "cash:eur" exists

  Scenario: An account's currency is immutable
    When I attempt to update the account "cash:eur" currency to USD
    Then the account update is rejected

  Scenario: An account's type is immutable
    When I attempt to update the account "cash:eur" type to liability
    Then the account update is rejected

  Scenario: Updating an account that does not exist fails
    When I update the account "ghost:eur" description to "nothing"
    Then the account update fails

  Scenario: An account without transactions can be deleted
    Given an equity account "capital:eur" in EUR
    When I delete the account "capital:eur"
    Then the account "capital:eur" no longer exists
    And no journal event is written for the deletion

  Scenario: An account with transactions cannot be deleted
    Given an equity account "capital:eur" in EUR
    And I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    When I delete the account "cash:eur"
    Then the account deletion is rejected
    And the account "cash:eur" still exists

  Scenario: An account with a balance history cannot be deleted
    Given an equity account "capital:eur" in EUR
    And I create a pending transaction of 10000 EUR between "cash:eur" and "capital:eur"
    When I delete the account "cash:eur"
    Then the account deletion is rejected
