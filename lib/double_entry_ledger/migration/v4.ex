defmodule DoubleEntryLedger.Migration.V4 do
  @moduledoc """
  Version 4 — compound `(entry_id, inserted_at)` index on
  `balance_history_entries`.

  Replaces the single-column `(entry_id)` index to support ordered lookups of
  the latest balance history entry per entry. The leading-column prefix also
  serves queries filtered by `entry_id` alone, so the old index is redundant.
  """

  use DoubleEntryLedger.Migration.Version

  @doc "Migrates a version 3 schema to version 4."
  @spec up(String.t()) :: :ok
  def up(prefix \\ default_prefix()) do
    drop(index(:balance_history_entries, [:entry_id], prefix: prefix))
    create(index(:balance_history_entries, [:entry_id, :inserted_at], prefix: prefix))

    :ok
  end

  @doc "Rolls a version 4 schema back to version 3."
  @spec down(String.t()) :: :ok
  def down(prefix \\ default_prefix()) do
    drop(index(:balance_history_entries, [:entry_id, :inserted_at], prefix: prefix))
    create(index(:balance_history_entries, [:entry_id], prefix: prefix))

    :ok
  end
end
