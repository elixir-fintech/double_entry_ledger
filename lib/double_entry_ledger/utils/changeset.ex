defmodule DoubleEntryLedger.Utils.Changeset do
  @moduledoc """
  Get all errors
  """
  @spec all_errors(Ecto.Changeset.t()) :: String.t()
  def all_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _}  ->
      "#{msg}"
    end)
    |> inspect()
  end
end
