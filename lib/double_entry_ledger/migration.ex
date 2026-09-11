defmodule DoubleEntryLedger.Migration do
  @moduledoc """
  Migrations for the DoubleEntryLedger package.

  ## Usage

  Generate migration files with the install task:

      mix double_entry_ledger.install

  Or create a migration manually:

      mix ecto.gen.migration setup_double_entry_ledger

  Then edit the generated file:

      defmodule MyApp.Repo.Migrations.SetupDoubleEntryLedger do
        use Ecto.Migration

        def up, do: DoubleEntryLedger.Migration.up()
        def down, do: DoubleEntryLedger.Migration.down()
      end

  ## Versioning

  Each version represents an incremental schema change:

    * Version 1 — initial schema (v0.1.0)
    * Version 2 — FK constraint fixes, `negative_limit` replaces `allowed_negative`
    * Version 3 — `trace_context` JSONB column on commands for distributed tracing.
      The column is not indexed — consumers who need to query by trace context
      should add their own index.
    * Version 4 — replace single-column `(entry_id)` index on `balance_history_entries`
      with compound `(entry_id, inserted_at)` index to support ordered lookups
      of the latest balance history entry per entry (leading-column prefix also
      serves queries filtered by `entry_id` alone).
    * Version 5 — the v0.5.0 schema change. Collapses the three
      `journal_event_*_links` join tables into direct nullable FK columns on
      `journal_events`, denormalizes a required `instance_id` onto
      `command_queue_items`, widens the account and balance-history balance
      and limit columns to `bigint`, adds a database-generated
      `queue_position` for stable command ordering, and moves command and
      queue-item timestamps — including the `next_retry_after` deadline
      computed from a transient `retry_delay_seconds` instruction — onto the
      PostgreSQL clock. See `DoubleEntryLedger.Migration.V5`.

  New consumers add a single migration calling `up()` / `down()` — all versions
  apply in order. Existing consumers upgrading to a new library release add a
  new migration per upgrade, using `:from` to skip already-applied versions:

      # Upgrade from v0.1.0 (version 1 already applied)
      def up, do: DoubleEntryLedger.Migration.up(from: 1)
      def down, do: DoubleEntryLedger.Migration.down(version: 1)

      # Upgrade from 0.3.x to 0.4.0 (versions 1-3 already applied)
      def up, do: DoubleEntryLedger.Migration.up(from: 3)
      def down, do: DoubleEntryLedger.Migration.down(from: 4, version: 3)

      # Upgrade from 0.4.x to 0.5.0 (versions 1-4 already applied)
      def up, do: DoubleEntryLedger.Migration.up(from: 4)
      def down, do: DoubleEntryLedger.Migration.down(from: 5, version: 4)

  ## Historical background-job migrations

  Version 0.5.0 no longer depends on or supervises the former job runner. If a
  v0.1.0 consumer copied its migration, the already-applied migration and its
  tables may remain. Applications that still need to execute or roll back that
  historical migration must declare the original dependency themselves.

  ## Options

    * `:version` - Target migration version. Defaults to `latest_version/0` for
      `up/1` and `0` (full rollback) for `down/1`.
    * `:from` - Starting version (what's already applied). Defaults to `0` for
      `up/1` and `latest_version/0` for `down/1`.
    * `:prefix` - Schema prefix. Defaults to the configured `:schema_prefix`
      or `"double_entry_ledger"`.
  """

  use Ecto.Migration

  alias DoubleEntryLedger.Migration.{V1, V2, V3, V4, V5}

  @latest_version 5

  @doc "Returns the latest migration version."
  @spec latest_version() :: pos_integer()
  def latest_version, do: @latest_version

  @doc """
  Runs migrations from `:from` up to `:version`.

  ## Options

    * `:version` - Target version. Defaults to `latest_version/0`.
    * `:from` - Starting version (already applied). Defaults to `0`.
    * `:prefix` - Schema prefix. Defaults to configured `:schema_prefix`.
  """
  @spec up(keyword()) :: :ok
  # The version ladder is intentionally explicit: one gate per migration
  # version, read in order. Collapsing it into a data-driven loop to satisfy
  # the complexity check would hide the ordering, which is the one thing a
  # reader of this function needs to see.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def up(opts \\ []) do
    version = Keyword.get(opts, :version, @latest_version)
    from = Keyword.get(opts, :from, 0)
    prefix = prefix(opts)

    if from < 1 and version >= 1 do
      V1.up(prefix)
      flush()
    end

    if from < 2 and version >= 2 do
      V2.up(prefix)
      flush()
    end

    if from < 3 and version >= 3 do
      V3.up(prefix)
      flush()
    end

    if from < 4 and version >= 4 do
      V4.up(prefix)
      flush()
    end

    if from < 5 and version >= 5, do: V5.up(prefix)

    :ok
  end

  @doc """
  Rolls back migrations from `:from` down to `:version`.

  ## Options

    * `:version` - Target version to roll back to. Defaults to `0` (full rollback).
    * `:from` - Current version (what's applied). Defaults to `latest_version/0`.
    * `:prefix` - Schema prefix. Defaults to configured `:schema_prefix`.
  """
  @spec down(keyword()) :: :ok
  # The version ladder is intentionally explicit: one gate per migration
  # version, read in order. Collapsing it into a data-driven loop to satisfy
  # the complexity check would hide the ordering, which is the one thing a
  # reader of this function needs to see.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def down(opts \\ []) do
    version = Keyword.get(opts, :version, 0)
    from = Keyword.get(opts, :from, @latest_version)
    prefix = prefix(opts)

    if from >= 5 and version < 5 do
      V5.down(prefix)
      flush()
    end

    if from >= 4 and version < 4 do
      V4.down(prefix)
      flush()
    end

    if from >= 3 and version < 3 do
      V3.down(prefix)
      flush()
    end

    if from >= 2 and version < 2 do
      V2.down(prefix)
      flush()
    end

    if from >= 1 and version < 1, do: V1.down(prefix)

    :ok
  end

  defp prefix(opts) do
    Keyword.get_lazy(opts, :prefix, fn ->
      Application.get_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")
    end)
  end
end
