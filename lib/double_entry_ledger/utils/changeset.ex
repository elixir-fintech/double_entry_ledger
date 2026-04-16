defmodule DoubleEntryLedger.Utils.Changeset do
  @moduledoc """
  Changeset helpers for error formatting and custom validations.
  """

  import Ecto.Changeset, only: [validate_change: 3]

  @default_max_trace_context_keys 10

  @doc """
  Validates that `trace_context` is a flat string-valued map with a bounded
  number of keys.

  The maximum number of keys defaults to #{@default_max_trace_context_keys} and can be
  overridden via application config:

      config :double_entry_ledger, max_trace_context_keys: 20

  Rejects nested maps, non-string values, and oversized maps to prevent
  abuse while remaining vendor-neutral.

  ## Examples

      changeset
      |> validate_trace_context(:trace_context)
  """
  @spec validate_trace_context(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_trace_context(changeset, field \\ :trace_context) do
    max_keys =
      Application.get_env(
        :double_entry_ledger,
        :max_trace_context_keys,
        @default_max_trace_context_keys
      )

    validate_change(changeset, field, fn _, value ->
      cond do
        map_size(value) > max_keys ->
          [{field, {"must have at most #{max_keys} keys", []}}]

        not Enum.all?(value, fn {_k, v} -> is_binary(v) end) ->
          [{field, {"values must be strings", []}}]

        true ->
          []
      end
    end)
  end

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
