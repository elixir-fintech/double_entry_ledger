defmodule DoubleEntryLedger.Currency do
  @moduledoc """
  Provides types and helper functions for currency handling within the ledger system.

  This module facilitates currency operations such as converting amounts to `Money` structs
  and retrieving supported currency atoms.
  """

  @type currency_atom ::
    unquote(
      Money.Currency.all
      |> Enum.map_join(" | ", fn {k, _v} -> k end)
      |> Code.string_to_quoted!()
    )


  @doc """
  Returns a list of all supported currency atoms.

  ## Examples

      iex> Currency.currency_atoms() |> Enum.sort() |> Enum.take(3)
      [:AED, :AFN, :ALL]
  """
  @spec currency_atoms() :: list()
  def currency_atoms do
    Money.Currency.all |> Enum.map(fn {k, _v} -> k end)
  end

  @doc """
  Converts an amount and a currency to a `Money` struct, ensuring the amount is positive.

  ## Parameters

    - `amount` - The integer amount to convert.
    - `currency` - The currency atom for the amount.

  ## Examples

      iex> Currency.to_abs_money(-100, :USD)
      %Money{amount: 100, currency: :USD}

  ## Returns

    - A `Money.t()` struct with an absolute value of the amount.
  """
  @spec to_abs_money(integer(), currency_atom()) :: Money.t()
  def to_abs_money(amount, currency) do
    Money.new(abs(amount), currency)
  end
end
