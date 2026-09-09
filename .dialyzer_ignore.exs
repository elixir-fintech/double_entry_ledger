# .dialyzer_ignore.exs
[
  # {file, warning_description}
  {"lib/mix/tasks/load_test.ex", :unknown_function},
  #  {"lib/double_entry_ledger/workers/event_worker/process_command.ex", :pattern_match}

  # False positive on Elixir 1.19 / OTP 28: `Ecto.Multi.new/0` returns a struct
  # literal whose `names` field is a `MapSet` with an opaque internal type, and
  # OTP 28's dialyzer flags the first `Multi.*` call on it. Fixed upstream in
  # Elixir 1.20; remove this entry after upgrading.
  # https://github.com/elixir-lang/elixir/issues/14576
  ~r/Type mismatch in call without opaque term/
]
