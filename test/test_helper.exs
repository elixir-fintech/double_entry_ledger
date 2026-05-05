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

Mox.defmock(DoubleEntryLedger.MockRepo, for: DoubleEntryLedger.RepoBehaviour)

Mox.defmock(DoubleEntryLedger.MockCommandWorker,
  for: DoubleEntryLedger.Workers.CommandWorkerBehaviour
)
