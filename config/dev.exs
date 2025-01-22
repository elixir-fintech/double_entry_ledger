import Config

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5432",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
