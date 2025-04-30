import Config

config :double_entry_ledger,
  ecto_repos: [DoubleEntryLedger.Repo],
  max_retries: 5,
  retry_interval: 200

# Event queue configuration
config :double_entry_ledger, :event_queue,
  poll_interval: 5_000,          # Poll for new events every 5 seconds
  max_retries: 5,                # Maximum number of retry attempts
  base_retry_delay: 30,          # Base delay in seconds for first retry
  max_retry_delay: 3600,         # Maximum delay in seconds (1 hour)
  processor_name: "event_queue"  # Name prefix for processors

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
