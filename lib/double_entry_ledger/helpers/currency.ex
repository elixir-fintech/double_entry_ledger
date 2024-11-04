defmodule DoubleEntryLedger.Currency do
  @moduledoc """
  Helper functions for currency handling.
  """

  @type currency_atom ::
    unquote(
      Money.Currency.all
      |> Enum.map_join(" | ", fn {k, _v} -> k end)
      |> Code.string_to_quoted!()
    )


  @doc """
  Returns a list of all currency atoms.
  """
  @spec currency_atoms() :: list()
  def currency_atoms do
    Money.Currency.all |> Enum.map(fn {k, _v} -> k end)
  end

  @doc """
  Converts an amount and a currency to a Money struct, ensuring the amount is positive.

  ## Examples

    iex> Currency.to_abs_money(-100, :USD)
    %Money{amount: 100, currency: :USD}
  """
  @spec to_abs_money(integer(), currency_atom()) :: Money.t()
  def to_abs_money(amount, currency) do
    Money.new(abs(amount), currency)
  end
end
