@wip
Feature: Account setup
  Accounts are the ledger's unit of balance. Each is created with a type,
  a currency, and an address unique within its instance. The account's
  normal balance direction follows from its type, and every new account
  starts from zero.

  Background:
    Given a ledger instance

  Scenario: Creating an account of each type assigns its normal balance direction
    Accounts of a debit-normal type record debits as increases; accounts
    of a credit-normal type record credits as increases.
    Given an asset account "cash:eur" in EUR
    And a liability account "loans:eur" in EUR
    And an equity account "capital:eur" in EUR
    And a revenue account "sales:eur" in EUR
    And an expense account "rent:eur" in EUR
    Then the account "cash:eur" has normal balance debit
    And the account "loans:eur" has normal balance credit
    And the account "capital:eur" has normal balance credit
    And the account "sales:eur" has normal balance credit
    And the account "rent:eur" has normal balance debit

  Scenario: A new account starts from zero balances
    Given an asset account "cash:eur" in EUR
    Then the posted balance of "cash:eur" is 0
    And the pending balance of "cash:eur" is 0
    And the available balance of "cash:eur" is 0

  Scenario: An account address must be unique within its instance
    Given an asset account "cash:eur" in EUR
    When I create an asset account "cash:eur" in EUR
    Then the account creation is rejected

  Scenario: An account address must match the addressing format
    Addresses are words of letters, digits, and underscores joined by
    colons. Spaces and other punctuation are rejected.
    When I create an asset account "cash account!" in EUR
    Then the account creation is rejected

  Scenario: An unsupported currency is rejected
    When I create an asset account "cash:xyz" in XYZ
    Then the account creation is rejected

  Scenario: An unsupported account type is rejected
    When I create a "miscellaneous" account "stuff:eur" in EUR
    Then the account creation is rejected

  Scenario: A missing currency is rejected
    When I create an asset account without a currency
    Then the account creation is rejected

  Scenario: A negative limit can be set on creation
    Given an asset account "cash:eur" in EUR with negative limit 10000
    Then the account "cash:eur" has negative limit 10000

  Scenario: A negative limit defaults to zero
    Given an asset account "cash:eur" in EUR
    Then the account "cash:eur" has negative limit 0

  Scenario: A negative limit itself must not be negative
    When I create an asset account "broken:eur" in EUR with negative limit -1
    Then the account creation is rejected

  Scenario: An explicit normal balance overrides the type's default
    A contra account records decreases on the side its type would
    normally increase.
    When I create an asset account "depreciation:eur" in EUR with normal balance credit
    Then the account "depreciation:eur" has normal balance credit
