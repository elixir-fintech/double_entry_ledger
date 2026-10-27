@wip
Feature: Command validation
  External requests enter as commands. Structural validation — action,
  instance, source, idempotency keys, status, entry count, distinct
  accounts — happens before anything is queued or stored: a malformed
  command creates no command row and no queue item, so bad input never
  occupies the queue. Ledger rules that need account state, such as
  balance and account existence, are checked only when the command is
  processed.

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

  Scenario: Balance is not checked when a command is enqueued
    Unbalanced entries are structurally valid, so the command is queued;
    it fails when processed (see command retries).
    When I enqueue a create transaction command from "back-office" with idempotency key "cap-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 100000 | EUR      |
      | capital:eur   | 90000  | EUR      |
    Then the command is stored with queue item status pending

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

  Scenario: A synchronous command in retry mode returns validation failures without storing them
    Retry mode only persists failures the queue can recover from;
    validation failures come back to the caller as in "fail" mode.
    When I synchronously process a create transaction command from "back-office" with idempotency key "cap-1" with error mode "retry" with entries:
      | account       | amount | currency |
      | ghost:eur     | 100000 | EUR      |
      | capital:eur   | 100000 | EUR      |
    Then the command fails without being stored

  Scenario: A synchronous command in retry mode stores an OCC timeout
    With "retry" a command whose optimistic concurrency retries are
    exhausted is persisted in occ_timeout so the queue can retry it.
    Given a synchronous create transaction command that exhausts its OCC retries
    When I synchronously process it with error mode "retry"
    Then the command is stored with queue item status occ_timeout
    And the queue item has a retry scheduled
