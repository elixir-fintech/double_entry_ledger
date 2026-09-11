defmodule DoubleEntryLedger.Migration.Version do
  @moduledoc false

  # Shared boilerplate for the per-version migration modules
  # (`DoubleEntryLedger.Migration.V1` … `V5`). It exists so the five of them do
  # not each repeat `use Ecto.Migration` plus an identical `default_prefix/0`.
  #
  # It is deliberately not a behaviour and carries no dispatch: each version
  # module is still called directly by name from `DoubleEntryLedger.Migration`.
  #
  # The `up(prefix \\ default_prefix())` / `down(prefix \\ default_prefix())`
  # default argument every version declares is load-bearing, not cosmetic:
  # `Ecto.Migration.flush/0` refuses to run during a rollback unless the module
  # it is called from exports `down/0`, and the default argument is what
  # generates that clause. It also lets a single version be driven directly by
  # `Ecto.Migrator`.

  defmacro __using__(_opts) do
    quote do
      use Ecto.Migration

      defp default_prefix do
        Application.get_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")
      end
    end
  end
end
