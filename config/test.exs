import Config

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5433",
  pool: Ecto.Adapters.SQL.Sandbox,
  stacktrace: true
