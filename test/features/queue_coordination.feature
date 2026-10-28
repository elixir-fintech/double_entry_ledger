@wip
Feature: Queue coordination
  Each node runs an instance monitor that discovers ledgers with
  processable commands, acquires their leases, and starts a processor
  per ledger. Enqueuing wakes the monitor, so new work does not wait for
  the next poll. Per-node limits bound how many ledgers a node works and
  how many command ids a processor buffers.

  Background:
    Given the command queue is running
    And a ledger instance
    And an asset account "cash:eur" in EUR
    And an equity account "capital:eur" in EUR

  Scenario: Enqueuing a command wakes the monitor
    Given the poll interval is longer than the scenario
    When I enqueue a create transaction command from "billing" with idempotency key "pay-1" with entries:
      | account       | amount | currency |
      | cash:eur      | 10000  | EUR      |
      | capital:eur   | 10000  | EUR      |
    Then the command is processed before the next poll
    And the posted balance of "cash:eur" is 10000

  Scenario: Only ledgers with processable commands are leased
    A ledger whose only command is waiting for a future retry has no
    work to do yet.
    Given a second ledger instance "idle:ledger" whose only command has a retry deadline in the future
    When the monitor polls
    Then the node does not acquire a lease for "idle:ledger"

  Scenario: A node works at most its configured number of ledgers
    Given the maximum number of leases per node is 2
    And 3 ledger instances with pending commands
    When the monitor polls
    Then the node holds 2 leases
    When those ledgers drain
    And the monitor polls
    Then the third ledger's commands are processed

  Scenario: A processor drains more commands than its fetch limit
    The fetch limit bounds the in-memory buffer of command ids, not the
    amount of work done.
    Given the pending fetch limit is 2
    And I enqueue 5 create transaction commands from "billing"
    When the monitor polls
    Then all 5 commands are processed
