defmodule DoubleEntryLedger.Features.Support.Sandbox do
  @moduledoc """
  Per-scenario setup for DoubleEntryLedger's feature tests.

  Checks out an Ecto SQL sandbox connection, so every scenario runs
  inside a transaction that is rolled back when the scenario's test
  process exits. The command pipeline runs synchronously in that same
  process (`start_command_queue: false` in the test config), so the
  checkout covers the instance, account and transaction steps alike.

  Scenarios that need per-scenario state beyond `:instance` (set by the
  "a ledger instance" step) can merge further keys into the context
  here, the way Edict's feature tests seed their configs.
  """

  use Cucumber.Hooks

  alias DoubleEntryLedger.Repo
  alias Ecto.Adapters.SQL.Sandbox

  before_scenario context do
    :ok = Sandbox.checkout(Repo)

    {:ok, context}
  end
end
