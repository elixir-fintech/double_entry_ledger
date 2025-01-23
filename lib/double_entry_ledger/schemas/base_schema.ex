defmodule DoubleEntryLedger.BaseSchema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      @schema_prefix "double_entry_ledger"
    end
  end
end
