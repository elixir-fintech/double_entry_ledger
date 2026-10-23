@wip
Feature: Telemetry events
  The library emits telemetry for every observable lifecycle change so
  consumers can monitor and alert. Each family of events carries the
  identifiers needed to correlate it with the entity it describes.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Creating an instance emits an instance created event
    Given no telemetry events have been observed
    When I create a ledger instance "acme:ledger"
    Then an "instance created" telemetry event is emitted for "acme:ledger"

  Scenario: Creating an account emits an account created event
    Given no telemetry events have been observed
    When I create a revenue account "sales:eur" in EUR
    Then an "account created" telemetry event is emitted
    And the event names the account type revenue

  Scenario: Updating an account emits an account updated event
    Given no telemetry events have been observed
    And a revenue account "sales:eur" in EUR
    When I update the account "sales:eur" description to "Sales revenue"
    Then an "account updated" telemetry event is emitted

  Scenario: Posting a transaction emits a transaction created event with status
    Given no telemetry events have been observed
    When I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    Then a "transaction created" telemetry event is emitted with status posted

  Scenario: Creating a hold emits a transaction created event with status pending
    Given no telemetry events have been observed
    When I create a pending transaction of 5000 EUR between "cash:eur" and "capital:eur"
    Then a "transaction created" telemetry event is emitted with status pending

  Scenario: Posting a hold emits a transaction posted event
    Given I create a pending transaction of 5000 EUR between "cash:eur" and "capital:eur"
    And no telemetry events have been observed since
    When I post the pending transaction
    Then a "transaction posted" telemetry event is emitted

  Scenario: Archiving a hold emits a transaction archived event
    Given I create a pending transaction of 5000 EUR between "cash:eur" and "capital:eur"
    And no telemetry events have been observed since
    When I archive the pending transaction
    Then a "transaction archived" telemetry event is emitted

  Scenario: Enqueuing a command emits a command enqueue event
    Given no telemetry events have been observed
    When I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    Then a "command enqueue" telemetry event is emitted

  Scenario: Claiming a command emits a command claim event
    Given I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    And no telemetry events have been observed since
    When the command queue processes the ledger's commands
    Then a "command claim" telemetry event is emitted

  Scenario: Processing a command emits a command process span
    Given no telemetry events have been observed
    When I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    Then "command process start" and "command process stop" telemetry events are emitted

  Scenario: A failing telemetry handler never breaks the ledger operation
    Telemetry is observational: a handler that raises is detached and
    the business write still succeeds.
    Given a telemetry handler that raises on every event
    When I create a posted transaction of 10000 EUR between "cash:eur" and "capital:eur"
    Then the posted balance of "cash:eur" is 10000
