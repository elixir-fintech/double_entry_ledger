import Config

config :double_entry_ledger,
  max_retries: 5,
  retry_interval: 10,
  start_command_queue: false

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5432",
  pool: Ecto.Adapters.SQL.Sandbox,
  stacktrace: true

config :logger,
  level: :warning

config :logger, :console,
  format: "$time $message $metadata[$level]\n",
  metadata: :all
