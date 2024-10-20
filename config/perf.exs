import Config

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo_performance",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5433",
  stacktrace: false,
  show_sensitive_data_on_connection_error: false,
  pool_size: 10,
  loggers: [{Ecto.LogEntry, :log, [:warn]}]
config :logger, level: :warn
