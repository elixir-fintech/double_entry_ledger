# .dialyzer_ignore.exs
[
  # False positive on Elixir 1.19 / OTP 28: `Ecto.Multi.new/0` returns a struct
  # literal whose `names` field is a `MapSet` with an opaque internal type, and
  # OTP 28's dialyzer flags the first `Multi.*` call on it. Fixed upstream in
  # Elixir 1.20; remove this entry after upgrading.
  # https://github.com/elixir-lang/elixir/issues/14576
  ~r/Type mismatch in call without opaque term/,

  # `@start_command_queue` is read with `Application.compile_env/3`, so within
  # any one build it is a literal. Dialyzer therefore sees the branch for the
  # other value as unreachable. Both branches are real: with
  # `start_command_queue: false` the library supervises no queue children at
  # all, disabling managed background processing. Nothing to fix in the code.
  {"lib/double_entry_ledger/application.ex", :pattern_match}
]
