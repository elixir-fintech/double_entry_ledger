defmodule DoubleEntryLedger.Features.Support.Sandbox do
  @moduledoc """
  Per-scenario setup for DoubleEntryLedger's feature tests.

  Starts an Ecto SQL sandbox owner, so every scenario runs inside a
  transaction that is rolled back when the scenario ends. Features are
  not async unless tagged `@async`, so the connection is shared: the
  processes a scenario starts itself — an `InstanceProcessor` and its
  worker tasks, since `start_command_queue: false` in the test config —
  write through the same connection as the steps, the way
  `DoubleEntryLedger.RepoCase` sets up the queue tests. An `@async`
  feature gets a private connection instead.

  Scenarios that need per-scenario state beyond `:instance` (set by the
  "a ledger instance" step) can merge further keys into the context
  here, the way Edict's feature tests seed their configs.
  """

  use Cucumber.Hooks

  alias DoubleEntryLedger.Repo
  alias Ecto.Adapters.SQL.Sandbox

  before_scenario context do
    pid = Sandbox.start_owner!(Repo, shared: not context.async)
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, context}
  end
end
