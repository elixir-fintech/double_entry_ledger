@wip
Feature: Account updates and deletion
  Accounts can have their descriptive fields (name, description,
  context) updated, but their identity — address, type, currency,
  normal balance — is fixed at creation. An update naming an identity
  field is not rejected: the field is ignored and the account keeps its
  original value. An account that has ever taken part in a transaction
  can never be deleted; an untouched account can.

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

  Scenario: An update cannot change an account's address
    When I update the account "cash:eur" address to "gold:eur"
    Then the account update succeeds
    And the account "cash:eur" exists
    And no account "gold:eur" exists

  Scenario: An update cannot change an account's currency
    When I update the account "cash:eur" currency to USD
    Then the account update succeeds
    And the account "cash:eur" has currency EUR

  Scenario: An update cannot change an account's type
    When I update the account "cash:eur" type to liability
    Then the account update succeeds
    And the account "cash:eur" has type asset
    And the account "cash:eur" has normal balance debit

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
