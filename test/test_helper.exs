ExUnit.start(formatters: [ExUnit.CLIFormatter])
ExUnit.configure(only_failures: true)

# Allow running the suite under either insert path. Defaults to
# :legacy; set INSERT_PATH=insert_all to exercise the new path.
case System.get_env("INSERT_PATH") do
  "insert_all" ->
    Application.put_env(:double_entry_ledger, :insert_path, :insert_all)
    # These mock-based tests inject legacy-specific repo call shapes;
    # the insert_all path uses additional Repo.all + Repo.update_all
    # calls which the existing mocks don't cover. Skip under
    # insert_all and rely on the equivalence script for coverage.
    ExUnit.configure(exclude: [:legacy_mock])

  _ ->
    :ok
end

Ecto.Adapters.SQL.Sandbox.mode(DoubleEntryLedger.Repo, :manual)

# `DoubleEntryLedger.LeaseFixtures.committed_lease/3` creates instances OUTSIDE
# the sandbox so a second connection can contend for a lease row lock, and
# deletes them in an `on_exit`. A run aborted between those two points would
# otherwise leave rows that every later test can see. Sweeping before and after
# the suite is idempotent and self-healing in both directions, so a leak from an
# aborted run cannot poison the next one.
#
# A plain Postgrex connection, not `Repo`: the sandbox is in :manual mode here,
# so `Repo` has no connection checked out, and the delete has to commit anyway.
defmodule DoubleEntryLedger.LeaseProbeSweep do
  @moduledoc false
  @prefix DoubleEntryLedger.Config.schema_prefix()

  def run do
    config = Application.fetch_env!(:double_entry_ledger, DoubleEntryLedger.Repo)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: Keyword.fetch!(config, :hostname),
        username: Keyword.fetch!(config, :username),
        password: Keyword.fetch!(config, :password),
        database: Keyword.fetch!(config, :database),
        port: config |> Keyword.fetch!(:port) |> to_string() |> String.to_integer()
      )

    Postgrex.query!(conn, "SET lock_timeout = '5s'", [])

    # Commands first: `commands.instance_id` is `on_delete: :nothing`, so one
    # leaked `LeaseFixtures.committed_command/2` row would make the instance
    # DELETE below raise a foreign key violation HERE, at load time, and the
    # whole suite would fail to start. Queue items cascade from commands.
    Postgrex.query!(
      conn,
      """
      DELETE FROM #{@prefix}.commands
      WHERE instance_id IN (
        SELECT id FROM #{@prefix}.instances WHERE address LIKE 'lease:probe:%'
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      "DELETE FROM #{@prefix}.instances WHERE address LIKE 'lease:probe:%'",
      []
    )

    GenServer.stop(conn)
    :ok
  end
end

DoubleEntryLedger.LeaseProbeSweep.run()
ExUnit.after_suite(fn _results -> DoubleEntryLedger.LeaseProbeSweep.run() end)

Mox.defmock(DoubleEntryLedger.MockRepo, for: DoubleEntryLedger.RepoBehaviour)

Mox.defmock(DoubleEntryLedger.MockCommandWorker,
  for: DoubleEntryLedger.Workers.CommandWorkerBehaviour
)
