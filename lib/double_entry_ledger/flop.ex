defmodule DoubleEntryLedger.Flop do
  @moduledoc """
  Flop backend bound to `DoubleEntryLedger.Repo`.

  All Store pagination helpers dispatch through this backend so consumers
  aren't required to configure a global `:flop, :repo` pointing at this
  library's repo. Host applications can define their own Flop backend
  against their own repo independently.
  """
  use Flop, repo: DoubleEntryLedger.Repo
end
