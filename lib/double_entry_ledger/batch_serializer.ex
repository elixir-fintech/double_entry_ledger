defmodule DoubleEntryLedger.BatchSerializer do
  @moduledoc """
  Serializes domain-specific embedded structs into JSONB-encodable
  plain maps for raw-SQL parameter binding via
  `Ecto.Adapters.SQL.query!/3`.

  Used by the batched write path (Step 3 of the multi-command batching
  plan). Single source of truth for these conversions so the writer
  doesn't sprinkle dumping logic throughout its SQL building.

  Only the conversions for which Postgrex/Jason can't do the right
  thing automatically live here. UUIDs, atoms (Ecto.Enum strings),
  DateTimes, and arbitrary maps are passed through to Postgrex
  directly with appropriate `::type` casts in the SQL.
  """

  alias DoubleEntryLedger.Balance

  @doc """
  Dump a `%Balance{}` to a plain JSONB-encodable map.

  Strips the `__struct__` key via `Map.from_struct/1`, producing
  `%{amount: integer, debit: integer, credit: integer}`. This matches
  the field set Ecto's embed dump produces for the `:posted` /
  `:pending` columns on `accounts`, so JSONB rows are byte-equivalent
  to what the legacy/`insert_all` paths write.
  """
  @spec dump_balance(Balance.t()) :: %{
          amount: integer(),
          debit: integer(),
          credit: integer()
        }
  def dump_balance(%Balance{} = balance), do: Map.from_struct(balance)

  @doc """
  Dump a `%Money{}` to a plain JSONB-encodable map matching what
  `Money.Ecto.Map.Type.dump/1` produces on insert.

  Delegates to `Money.Ecto.Map.Type.dump/1` (unwrapping the `{:ok, _}`
  Ecto type contract) so the on-disk JSONB representation is
  byte-identical to what the legacy/`insert_all` paths write for
  `entries.value`.
  """
  @spec dump_money(Money.t()) :: %{String.t() => integer() | String.t()}
  def dump_money(%Money{} = money) do
    {:ok, dumped} = Money.Ecto.Map.Type.dump(money)
    dumped
  end
end
