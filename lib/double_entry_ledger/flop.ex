defmodule DoubleEntryLedger.Flop do
  @moduledoc """
  Flop backend bound to the repo configured via `DoubleEntryLedger.Config`.

  All Store pagination helpers dispatch through this backend so consumers
  aren't required to configure a global `:flop, :repo` — and so the library
  honours `config :double_entry_ledger, repo: MyApp.Repo` without further
  wiring. Host applications can define their own Flop backend against their
  own repo independently.
  """
  use Flop, repo: DoubleEntryLedger.Config.repo()
end
