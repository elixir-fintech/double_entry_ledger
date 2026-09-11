defmodule DoubleEntryLedger.Migration.V3 do
  @moduledoc """
  Version 3 — `trace_context` JSONB column on `commands` for distributed
  tracing.

  The column is not indexed — consumers who need to query by trace context
  should add their own index.
  """

  use DoubleEntryLedger.Migration.Version

  @doc "Migrates a version 2 schema to version 3."
  @spec up(String.t()) :: :ok
  def up(prefix \\ default_prefix()) do
    alter table(:commands, prefix: prefix) do
      add(:trace_context, :map, null: true)
    end

    :ok
  end

  @doc "Rolls a version 3 schema back to version 2."
  @spec down(String.t()) :: :ok
  def down(prefix \\ default_prefix()) do
    alter table(:commands, prefix: prefix) do
      remove(:trace_context)
    end

    :ok
  end
end
