@wip
Feature: Command validation
  External requests enter as commands. Payload validation happens
  before anything is queued or stored: an invalid command creates no
  command row and no queue item, so bad input never occupies the
  queue.

  Background:
    Given a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: A well-formed create transaction command is accepted
    When I enqueue a create transaction command from "back-office" with idempotency key "cap-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    Then the command is stored with queue item status pending

  Scenario: An unsupported action is rejected
    When I enqueue a command with action "teleport_account"
    Then the command is rejected with reason "action_not_supported"
    And no command is stored

  Scenario: A command without an action is rejected
    When I enqueue a command without an action
    Then the command is rejected
    And no command is stored

  Scenario: A create command missing its idempotency key is rejected
    When I enqueue a create transaction command from "back-office" without an idempotency key
    Then the command is rejected
    And no command is stored

  Scenario: A source must be a short lowercase identifier
    When I enqueue a create transaction command from "Back-Office" with idempotency key "cap-1"
    Then the command is rejected
    And no command is stored

  Scenario: An update command missing its update idempotency key is rejected
    When I enqueue an update transaction command from "back-office" with idempotency key "cap-1" without an update idempotency key
    Then the command is rejected
    And no command is stored

  Scenario: A create command referencing an unknown instance is rejected
    When I enqueue a create transaction command for instance "ghost:ledger" from "back-office" with idempotency key "cap-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    Then the command is rejected
    And no command is stored

  Scenario: Unbalanced entries fail validation before queuing
    When I enqueue a create transaction command from "back-office" with idempotency key "cap-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
    Then the command is rejected
    And no command is stored

  Scenario: A create account command with an invalid payload is rejected
    When I enqueue a create account command from "back-office" with an empty payload
    Then the command is rejected
    And no command is stored

  Scenario: A synchronous command can surface failures without storing them
    Transaction actions accept an error mode: with "fail" the caller
    gets the validation error directly and nothing is persisted.
    When I synchronously process a create transaction command from "back-office" with idempotency key "cap-1" with error mode "fail" with entries:
      | account       | amount | currency |
      | ghost:eur     | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    Then the command fails without being stored

  Scenario: A synchronous command in retry mode stores its failure
    With "retry" the failing command is persisted with its error state
    so the queue can retry it.
    When I synchronously process a create transaction command from "back-office" with idempotency key "cap-1" with error mode "retry" with entries:
      | account       | amount | currency |
      | ghost:eur     | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    Then the command is stored with its failure recorded
