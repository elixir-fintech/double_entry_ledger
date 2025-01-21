# DoubleEntryLedger

DoubleEntryLedger is an Elixir library for managing a double-entry accounting ledger. A double-entry ledger ensures that every financial transaction is recorded in at least two accounts, with debits equaling credits, to maintain the accounting equation: Assets = Liabilities + Equity.

## Installation

Since the package is not yet available on Hex, you can install it by adding `double_entry_ledger` to your list of dependencies in `mix.exs` and specifying the GitHub repository:

```elixir
def deps do
  [
    {:double_entry_ledger, git: "https://github.com/your_username/double_entry_ledger.git", branch: "main"}
  ]
end
```

## Migrations

You will need to add the necessary migrations to your own project to create the required database tables. You can generate a migration file and define the schema for `instances`, `accounts`, and other related tables. Copy the migration files from this project to your own project's `priv/repo/migrations` directory and then run the migrations:

```sh
# Copy the migration content from this project to the generated migration file
mix ecto.migrate
```

## Usage

This library provides modules and functions to create, update, and manage ledger instances, accounts, and transactions. It ensures that all transactions are balanced and maintains the integrity of the ledger.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/double_entry_ledger>.

```sh
mix docs
```

## Note

This library is still under development and is not yet ready for primetime. Use it at your own risk and feel free to contribute to its development.

