defmodule DoubleEntryLedger.Utils.Changeset do
  @moduledoc """
  Get all errors
  """

  @spec all_errors(Ecto.Changeset.t()) :: String.t()
  def all_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} ->
      "#{msg}"
    end)
    |> inspect()
  end

  @doc """
  Returns errors grouped by field as a map of lists of `{message_template, opts}` tuples.

  Messages are not interpolated; templates and their options are preserved for
  downstream formatting, translation, or logging.
  """
  def all_errors_with_opts(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      {msg, opts}
    end)
    |> inspect()
  end
end
