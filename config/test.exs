import Config

config :double_entry_ledger,
  max_retries: 5,
  retry_interval: 10

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5432",
  pool: Ecto.Adapters.SQL.Sandbox,
  stacktrace: true
