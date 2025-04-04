import Config

config :double_entry_ledger,
  ecto_repos: [DoubleEntryLedger.Repo],
  max_retries: 5,
  retry_interval: 200

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
