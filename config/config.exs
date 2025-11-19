import Config

config :logger,
  formatter: {LoggerJSON.Formatters.Basic, metadata: :all}

config :double_entry_ledger,
  ecto_repos: [DoubleEntryLedger.Repo],
  max_retries: 5,
  retry_interval: 200,
  schema_prefix: "double_entry_ledger",
  # set this for test and development
  idempotency_secret: "lskfdjsdkfjsdkj"

# Event queue configuration
config :double_entry_ledger, :command_queue,
  # Poll for new events every 5 seconds
  poll_interval: 5_000,
  # Maximum number of retry attempts
  max_retries: 5,
  # Base delay in seconds for first retry
  base_retry_delay: 30,
  # Maximum delay in seconds (1 hour)
  max_retry_delay: 3600,
  # Name prefix for processors
  processor_name: "command_queue"

config :double_entry_ledger, Oban,
  engine: Oban.Engines.Basic,
  queues: [double_entry_ledger: 1],
  repo: DoubleEntryLedger.Repo,
  prefix: "double_entry_ledger"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
