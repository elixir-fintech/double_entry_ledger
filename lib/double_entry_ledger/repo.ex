defmodule DoubleEntryLedger.Repo do
  use Ecto.Repo,
    otp_app: :double_entry_ledger,
    adapter: Ecto.Adapters.Postgres

  @behaviour DoubleEntryLedger.RepoBehaviour
end
