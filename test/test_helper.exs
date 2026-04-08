ExUnit.start(formatters: [ExUnit.CLIFormatter])
ExUnit.configure(only_failures: true)

Ecto.Adapters.SQL.Sandbox.mode(DoubleEntryLedger.Repo, :manual)

Mox.defmock(DoubleEntryLedger.MockRepo, for: DoubleEntryLedger.RepoBehaviour)

Mox.defmock(DoubleEntryLedger.MockCommandWorker,
  for: DoubleEntryLedger.Workers.CommandWorkerBehaviour
)
