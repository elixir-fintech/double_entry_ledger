import Config

# Honor INSERT_PATH=insert_all across all environments. Defaults to
# :legacy. Used to flip CreateTransactionCommand between the original
# cascade build path and the parallel insert_all path during perf
# validation.
case System.get_env("INSERT_PATH") do
  "insert_all" -> config :double_entry_ledger, insert_path: :insert_all
  _ -> :ok
end

# BATCH=on flips the InstanceProcessor between the per-command Task path and
# the multi-command BatchProcessor path during perf validation. It lives in
# the `:command_queue` list, the one place `CommandQueue.Config` reads and
# `validate!/0` checks at boot. `config/3` deep-merges keyword lists, so this
# sets one key and leaves the rest of `:command_queue` alone.
case System.get_env("BATCH") do
  "on" -> config :double_entry_ledger, :command_queue, batch_enabled: true
  _ -> :ok
end

# BATCH_SIZE=N sweeps the batch size across M values during perf validation.
case System.get_env("BATCH_SIZE") do
  size when is_binary(size) ->
    config :double_entry_ledger, :command_queue, batch_size: String.to_integer(size)

  _ ->
    :ok
end
