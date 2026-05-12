import Config

# Honor INSERT_PATH=insert_all across all environments. Defaults to
# :legacy. Used to flip CreateTransactionCommand between the original
# cascade build path and the parallel insert_all path during perf
# validation.
case System.get_env("INSERT_PATH") do
  "insert_all" -> config :double_entry_ledger, insert_path: :insert_all
  _ -> :ok
end

# Honor BATCH=on across all environments. Defaults to false. Used to
# flip InstanceProcessor between the per-command Task path and the
# multi-command BatchProcessor path during perf validation.
case System.get_env("BATCH") do
  "on" -> config :double_entry_ledger, batch_enabled: true
  _ -> :ok
end

# Override the InstanceProcessor batch size when BATCH_SIZE is set.
# Used to sweep across M values during perf validation. The
# `:batch_size` top-level key is the override; the InstanceProcessor
# falls back to its hardcoded default of 8 if neither is set.
case System.get_env("BATCH_SIZE") do
  size when is_binary(size) -> config :double_entry_ledger, batch_size: String.to_integer(size)
  _ -> :ok
end
