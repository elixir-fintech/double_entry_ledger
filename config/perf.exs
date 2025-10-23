import Config

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo_performance",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5432",
  stacktrace: false,
  show_sensitive_data_on_connection_error: false,
  pool_size: 10

config :logger, level: :warning

config :double_entry_ledger, Oban, testing: :manual
