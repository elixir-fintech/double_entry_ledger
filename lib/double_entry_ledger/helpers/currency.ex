defmodule DoubleEntryLedger.Currency do
  @moduledoc """
  Helper functions for currency handling.
  """

  @type currency_atom ::
    unquote(
      Money.Currency.all
      |> Enum.map_join(" | ", fn {k, _v} -> inspect(k) end)
      |> Code.string_to_quoted!()
    )

  @spec currency_atoms() :: list()
  def currency_atoms do
    Money.Currency.all |> Enum.map(fn {k, _v} -> k end)
  end
end
