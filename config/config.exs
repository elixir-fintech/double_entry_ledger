import Config

config :double_entry_ledger,
  ecto_repos: [DoubleEntryLedger.Repo],
  max_retries: 5,
  retry_interval: 200

# Event queue configuration
config :double_entry_ledger, :event_queue,
  # Poll for new events every 5 seconds
  poll_interval: 5_000,
  # Maximum number of retry attempts
  max_retries: 5,
  # Base delay in seconds for first retry
  base_retry_delay: 30,
  # Maximum delay in seconds (1 hour)
  max_retry_delay: 3600,
  # Name prefix for processors
  processor_name: "event_queue"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
