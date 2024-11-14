ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(DoubleEntryLedger.Repo, :manual)

Mox.defmock(DoubleEntryLedger.MockRepo, for: DoubleEntryLedger.RepoBehaviour)
