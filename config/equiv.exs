import Config

# Dedicated environment for the multi-command batching equivalence
# script. Uses its own database so the script can't leak rows into the
# `:test` DB (which broke `instance_store_test` after a leftover
# `instance:eq:b` row hung around between runs).
#
# Run with:
#   MIX_ENV=equiv mix run test/performance/batch_equivalence.exs

config :double_entry_ledger,
  max_retries: 5,
  retry_interval: 10,
  start_command_queue: false

config :double_entry_ledger, DoubleEntryLedger.Repo,
  database: "double_entry_ledger_repo_equivalence",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5432",
  stacktrace: true

config :double_entry_ledger, Oban, testing: :manual, prefix: "double_entry_ledger"

config :logger, level: :warning
