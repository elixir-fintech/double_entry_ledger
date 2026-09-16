defmodule DoubleEntryLedger.Migration.V6 do
  @moduledoc """
  Version 6 — per-ledger leases for multi-node command processing.

  Adds `command_queue_leases`, one row per instance: the current owner, a
  fencing token that increases on every takeover, and a database-clock
  expiry. Rows are never deleted by the application; a graceful release marks
  the row expired and the next acquisition takes it over.
  """

  use DoubleEntryLedger.Migration.Version

  @doc "Migrates a version 5 schema to version 6."
  @spec up(String.t()) :: :ok
  def up(prefix \\ default_prefix()) do
    create table(:command_queue_leases, primary_key: false, prefix: prefix) do
      add(:instance_id, references(:instances, on_delete: :delete_all, type: :binary_id),
        primary_key: true
      )

      add(:owner_id, :text, null: false)
      add(:fencing_token, :bigint, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:acquired_at, :utc_datetime_usec, null: false)
      add(:renewed_at, :utc_datetime_usec)
      add(:released_at, :utc_datetime_usec)
    end

    create(
      index(:command_queue_leases, [:expires_at],
        prefix: prefix,
        name: :idx_command_queue_leases_expires_at
      )
    )

    :ok
  end

  @doc """
  Refuses. Migration 6 is one-way: any 0.6 processor still running would lose
  its lease table. Return to 0.5 only by restoring a database backup taken
  before `up/1`.
  """
  @spec down(String.t()) :: no_return()
  def down(_prefix \\ default_prefix()) do
    raise "migration 6 is one-way; restore a database backup to return to 0.5"
  end
end
