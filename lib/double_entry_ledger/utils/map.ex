defmodule DoubleEntryLedger.Utils.Map do
  @moduledoc """
  Provides helper functions for working with maps in the context of the double-entry ledger.
  """
  def deep_atomize_keys!(%{__struct__: _} = struct), do: struct

  def deep_atomize_keys!(%{} = map) do
    map
    |> Enum.map(fn {k, v} ->
      key =
        case k do
          a when is_atom(a) -> a
          s when is_binary(s) -> String.to_existing_atom(s)
        end

      {key, deep_atomize_keys!(v)}
    end)
    |> Enum.into(%{})
  end

  def deep_atomize_keys!([h | t]), do: [deep_atomize_keys!(h) | deep_atomize_keys!(t)]
  def deep_atomize_keys!([]), do: []
  def deep_atomize_keys!(other), do: other
end
