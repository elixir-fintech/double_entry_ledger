defmodule DoubleEntryLedger.Currency do
  @moduledoc """
  Provides types and helper functions for currency handling within the ledger system.

  This module facilitates currency operations such as converting amounts to `Money` structs
  and retrieving supported currency atoms.
  """
  @currency_atoms Money.Currency.all
                  |> Enum.map(fn {k, _v} -> k end)
                  |> Enum.uniq()

  @type currency_atom :: unquote(
    Enum.reduce(
      @currency_atoms, fn state, acc -> quote do: unquote(state) | unquote(acc)
      end
      )
    )

  @doc """
  Returns a list of all supported currency atoms.

  ## Examples

      iex> Currency.currency_atoms() |> Enum.sort() |> Enum.take(3)
      [:AED, :AFN, :ALL]
  """
  @spec currency_atoms() :: list(currency_atom())
  def currency_atoms(), do: @currency_atoms

  @doc """
  Converts an amount and a currency to a `Money` struct, ensuring the amount is positive.

  ## Parameters

    - `amount` - The integer amount to convert.
    - `currency` - The currency atom for the amount.

  ## Examples

      iex> Currency.to_abs_money(-100, :USD)
      %Money{amount: 100, currency: :USD}

      iex> Currency.to_abs_money(100, "USD")
      %Money{amount: 100, currency: :USD}

      iex> Currency.to_abs_money(100, "XYZ")
      {:error, "Invalid currency"}

      iex> Currency.to_abs_money("100", 100)
      {:error, "Invalid amount or currency"}

  ## Returns

    - A `Money.t()` struct with an absolute value of the amount.
  """
  # credo:disable-for-next-line Credo.Check.Warning.SpecWithStruct
  @spec to_abs_money(integer(), currency_atom() | binary()) :: %Money{:amount => integer(), :currency => currency_atom()} | {:error, String.t()}
  def to_abs_money(amount, currency) when is_integer(amount) and currency in @currency_atoms do
    Money.new(abs(amount), currency)
  end

  def to_abs_money(amount, currency) when is_integer(amount) and is_binary(currency) do
    try do
      Money.new(abs(amount), String.to_existing_atom(currency))
    rescue ArgumentError ->
      {:error, "Invalid currency"}
    end
  end

  def to_abs_money(_amount, _currency), do: {:error, "Invalid amount or currency"}

end
