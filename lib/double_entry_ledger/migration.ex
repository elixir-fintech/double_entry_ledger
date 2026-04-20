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

  New consumers use `up()` which applies all versions. Existing consumers
  upgrading from v0.1.0 use the `:from` option to skip already-applied versions:

      # Upgrade from v0.1.0 (version 1 already applied via copied migrations)
      def up, do: DoubleEntryLedger.Migration.up(from: 1)
      def down, do: DoubleEntryLedger.Migration.down(version: 1)

  ## Oban

  This module does **not** manage Oban tables. The package does not ship an Oban
  migration to avoid locking consumers to a specific Oban version. Consumers
  manage Oban through their own application — see the README for setup
  instructions.

  If upgrading from v0.1.0, your existing copied `2500_add_oban_jobs_table.exs`
  continues to work — leave it in place.

  ## Options

    * `:version` - Target migration version. Defaults to `latest_version/0`.
    * `:from` - Starting version (what's already applied). Defaults to `0` for
      `up/1` and `latest_version/0` for `down/1`.
    * `:prefix` - Schema prefix. Defaults to the configured `:schema_prefix`
      or `"double_entry_ledger"`.
  """

  use Ecto.Migration

  @latest_version 4

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
  def up(opts \\ []) do
    version = Keyword.get(opts, :version, @latest_version)
    from = Keyword.get(opts, :from, 0)
    prefix = prefix(opts)

    if from < 1 and version >= 1 do
      v1_up(prefix)
      flush()
    end

    if from < 2 and version >= 2 do
      v2_up(prefix)
      flush()
    end

    if from < 3 and version >= 3 do
      v3_up(prefix)
      flush()
    end

    if from < 4 and version >= 4, do: v4_up(prefix)

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
  def down(opts \\ []) do
    version = Keyword.get(opts, :version, 0)
    from = Keyword.get(opts, :from, @latest_version)
    prefix = prefix(opts)

    if from >= 4 and version < 4 do
      v4_down(prefix)
      flush()
    end

    if from >= 3 and version < 3 do
      v3_down(prefix)
      flush()
    end

    if from >= 2 and version < 2 do
      v2_down(prefix)
      flush()
    end

    if from >= 1 and version < 1, do: v1_down(prefix)

    :ok
  end

  defp prefix(opts) do
    Keyword.get_lazy(opts, :prefix, fn ->
      Application.get_env(:double_entry_ledger, :schema_prefix, "double_entry_ledger")
    end)
  end

  # ── Version 1: Initial schema (v0.1.0) ────────────────────────────

  defp v1_up(prefix) do
    create_schema(prefix)
    create_instances(prefix)
    create_accounts_v1(prefix)
    create_transactions_v1(prefix)
    create_entries(prefix)
    create_commands(prefix)
    create_command_queue_items(prefix)
    create_balance_history_entries(prefix)
    create_journal_events(prefix)
    create_pending_transaction_lookup(prefix)
    create_journal_event_transaction_links(prefix)
    create_journal_event_account_links(prefix)
    create_journal_event_command_links(prefix)
    create_idempotency_keys(prefix)
  end

  defp v1_down(prefix) do
    drop_if_exists(table(:idempotency_keys, prefix: prefix))
    drop_if_exists(table(:journal_event_command_links, prefix: prefix))
    drop_if_exists(table(:journal_event_account_links, prefix: prefix))
    drop_if_exists(table(:journal_event_transaction_links, prefix: prefix))
    drop_if_exists(table(:pending_transaction_lookup, prefix: prefix))
    drop_if_exists(table(:journal_events, prefix: prefix))
    drop_if_exists(table(:balance_history_entries, prefix: prefix))
    drop_if_exists(table(:command_queue_items, prefix: prefix))
    drop_if_exists(table(:commands, prefix: prefix))
    drop_if_exists(table(:entries, prefix: prefix))
    drop_if_exists(table(:transactions, prefix: prefix))
    drop_if_exists(table(:accounts, prefix: prefix))
    drop_if_exists(table(:instances, prefix: prefix))
    execute("DROP SCHEMA IF EXISTS #{prefix}")
  end

  # ── Version 2: FK fixes + negative_limit ───────────────────────────

  @max_int32 2_147_483_647

  defp v2_up(prefix) do
    # Fix accounts FK from :restrict to :nothing (Ecto-compatible)
    drop(constraint(:accounts, "accounts_instance_id_fkey", prefix: prefix))

    alter table(:accounts, prefix: prefix) do
      modify(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
      )
    end

    # Fix transactions FK from :restrict to :nothing
    drop(constraint(:transactions, "transactions_instance_id_fkey", prefix: prefix))

    alter table(:transactions, prefix: prefix) do
      modify(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
      )
    end

    # Fix allowed_negative default from true to false
    alter table(:accounts, prefix: prefix) do
      modify(:allowed_negative, :boolean, default: false)
    end

    # Replace allowed_negative with negative_limit
    alter table(:accounts, prefix: prefix) do
      add(:negative_limit, :integer, null: false, default: 0)
    end

    flush()

    execute("""
    UPDATE #{prefix}.accounts
    SET negative_limit = #{@max_int32}
    WHERE allowed_negative = true
    """)

    alter table(:accounts, prefix: prefix) do
      remove(:allowed_negative)
    end
  end

  defp v2_down(prefix) do
    # Restore allowed_negative
    alter table(:accounts, prefix: prefix) do
      add(:allowed_negative, :boolean, null: false, default: false)
    end

    flush()

    execute("""
    UPDATE #{prefix}.accounts
    SET allowed_negative = true
    WHERE negative_limit > 0
    """)

    alter table(:accounts, prefix: prefix) do
      remove(:negative_limit)
    end

    # Restore allowed_negative default to true
    alter table(:accounts, prefix: prefix) do
      modify(:allowed_negative, :boolean, default: true)
    end

    # Restore transactions FK to :restrict
    drop(constraint(:transactions, "transactions_instance_id_fkey", prefix: prefix))

    alter table(:transactions, prefix: prefix) do
      modify(:instance_id, references(:instances, on_delete: :restrict, type: :binary_id),
        null: false
      )
    end

    # Restore accounts FK to :restrict
    drop(constraint(:accounts, "accounts_instance_id_fkey", prefix: prefix))

    alter table(:accounts, prefix: prefix) do
      modify(:instance_id, references(:instances, on_delete: :restrict, type: :binary_id),
        null: false
      )
    end
  end

  # ── Version 3: trace_context on commands ────────────────────────────

  defp v3_up(prefix) do
    alter table(:commands, prefix: prefix) do
      add(:trace_context, :map, null: true)
    end
  end

  defp v3_down(prefix) do
    alter table(:commands, prefix: prefix) do
      remove(:trace_context)
    end
  end

  # ── Version 4: compound (entry_id, inserted_at) index on balance_history_entries ──

  defp v4_up(prefix) do
    drop(index(:balance_history_entries, [:entry_id], prefix: prefix))
    create(index(:balance_history_entries, [:entry_id, :inserted_at], prefix: prefix))
  end

  defp v4_down(prefix) do
    drop(index(:balance_history_entries, [:entry_id, :inserted_at], prefix: prefix))
    create(index(:balance_history_entries, [:entry_id], prefix: prefix))
  end

  # ── V1 table definitions ───────────────────────────────────────────

  defp create_schema(prefix) do
    execute("CREATE SCHEMA IF NOT EXISTS #{prefix}")
  end

  defp create_instances(prefix) do
    create table(:instances, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:address, :string, null: false)
      add(:description, :string)
      add(:config, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:instances, [:address],
        prefix: prefix,
        name: "unique_address",
        include: [:id]
      )
    )
  end

  defp create_accounts_v1(prefix) do
    create table(:accounts, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:address, :string, null: false)
      add(:name, :string)
      add(:description, :string)
      add(:currency, :string, null: false)
      add(:normal_balance, :string, null: false)
      add(:type, :string, null: false)
      add(:context, :map, default: %{})
      add(:posted, :map, default: %{})
      add(:pending, :map, default: %{})
      add(:available, :integer, null: false, default: 0)
      add(:allowed_negative, :boolean, default: true)

      add(:instance_id, references(:instances, on_delete: :restrict, type: :binary_id),
        null: false
      )

      add(:lock_version, :integer, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:accounts, :address_format_chk,
        prefix: prefix,
        check: "address ~ '^_?[A-Za-z0-9]+(:[A-Za-z0-9_]+)*$'"
      )
    )

    create(index(:accounts, [:instance_id], prefix: prefix))

    create(
      unique_index(:accounts, [:instance_id, :address],
        prefix: prefix,
        name: "unique_address_per_instance",
        include: [:id]
      )
    )
  end

  defp create_transactions_v1(prefix) do
    create table(:transactions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:status, :string, null: false)
      add(:posted_at, :utc_datetime_usec)

      add(:instance_id, references(:instances, on_delete: :restrict, type: :binary_id),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:transactions, [:instance_id], prefix: prefix))
  end

  defp create_entries(prefix) do
    create table(:entries, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:type, :string, null: false)
      add(:value, :map)

      add(:transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id),
        null: false
      )

      add(:account_id, references(:accounts, on_delete: :nothing, type: :binary_id), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:entries, [:transaction_id], prefix: prefix))
    create(index(:entries, [:account_id], prefix: prefix))
  end

  defp create_commands(prefix) do
    create table(:commands, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
      )

      add(:command_map, :map, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:commands, [:inserted_at], prefix: prefix))
    create(index(:commands, [:instance_id], prefix: prefix))

    create(
      index(
        :commands,
        [:instance_id, "(command_map->>'source')", "(command_map->>'source_idempk')"],
        where: "command_map->>'action' = 'create_transaction'",
        name: "idx_commands_create_transaction_triple_expr",
        prefix: prefix,
        include: [:id]
      )
    )

    create(
      index(
        :commands,
        [
          :instance_id,
          "(command_map->>'source')",
          "(command_map->>'source_idempk')",
          "(command_map->>'update_idempk')"
        ],
        where: "command_map->>'action' = 'update_transaction'",
        name: "idx_commands_update_transaction_triple_expr",
        prefix: prefix,
        include: [:id]
      )
    )
  end

  defp create_command_queue_items(prefix) do
    create table(:command_queue_items, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(:command_id, references(:commands, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(:status, :string, null: false, default: "pending")
      add(:processor_id, :string, null: true)
      add(:processor_version, :integer, default: 1, null: false)
      add(:processing_started_at, :utc_datetime_usec)
      add(:processing_completed_at, :utc_datetime_usec)
      add(:retry_count, :integer, default: 0, null: false)
      add(:next_retry_after, :utc_datetime_usec)
      add(:occ_retry_count, :integer, default: 0, null: false)
      add(:errors, :jsonb, default: "[]")

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:command_queue_items, :command_id, prefix: prefix))
    create(index(:command_queue_items, :processing_completed_at, prefix: prefix))
    create(index(:command_queue_items, :status, prefix: prefix))
    create(index(:command_queue_items, :next_retry_after, prefix: prefix))

    create(
      index(:command_queue_items, [:next_retry_after, :status],
        prefix: prefix,
        name: "idx_command_queue_items_next_retry_status"
      )
    )

    create(
      index(:command_queue_items, [:status, :inserted_at],
        prefix: prefix,
        where: "status = 'dead_letter'",
        name: "idx_command_queue_items_dead_letter_queue"
      )
    )
  end

  defp create_balance_history_entries(prefix) do
    create table(:balance_history_entries, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:posted, :map, default: %{})
      add(:pending, :map, default: %{})
      add(:available, :integer, null: false, default: 0)
      add(:account_id, references(:accounts, on_delete: :nothing, type: :binary_id), null: false)
      add(:entry_id, references(:entries, on_delete: :nothing, type: :binary_id), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:balance_history_entries, [:account_id], prefix: prefix))
    create(index(:balance_history_entries, [:entry_id], prefix: prefix))
  end

  defp create_journal_events(prefix) do
    create table(:journal_events, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
      )

      add(:command_map, :map, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:journal_events, [:inserted_at], prefix: prefix))
    create(index(:journal_events, [:instance_id], prefix: prefix))

    create(
      index(
        :journal_events,
        [
          :instance_id,
          "(command_map->>'action')",
          "(command_map->>'source')",
          "(command_map->>'source_idempk')"
        ],
        name: "idx_journal_events_create_transaction_triple_expr",
        prefix: prefix,
        include: [:id]
      )
    )

    create(
      index(
        :journal_events,
        [
          :instance_id,
          "(command_map->>'source')",
          "(command_map->>'source_idempk')",
          "(command_map->>'update_idempk')"
        ],
        where: "command_map->>'action' = 'update_transaction'",
        name: "idx_journal_events_update_transaction_triple_expr",
        prefix: prefix,
        include: [:id]
      )
    )
  end

  defp create_pending_transaction_lookup(prefix) do
    create table(:pending_transaction_lookup, primary_key: false, prefix: prefix) do
      add(:instance_id, references(:instances, type: :binary_id), primary_key: true)
      add(:source, :text, primary_key: true)
      add(:source_idempk, :text, primary_key: true)

      add(:command_id, references(:commands, type: :binary_id, on_delete: :nilify_all))
      add(:transaction_id, references(:transactions, type: :binary_id))
      add(:journal_event_id, references(:journal_events, type: :binary_id))

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:pending_transaction_lookup, [:instance_id], prefix: prefix))
    create(index(:pending_transaction_lookup, [:command_id], prefix: prefix))
    create(index(:pending_transaction_lookup, [:transaction_id], prefix: prefix))
    create(index(:pending_transaction_lookup, [:journal_event_id], prefix: prefix))
  end

  defp create_journal_event_transaction_links(prefix) do
    create table(:journal_event_transaction_links, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(:transaction_id, references(:transactions, on_delete: :nothing, type: :binary_id),
        null: false
      )

      add(:journal_event_id, references(:journal_events, on_delete: :nothing, type: :binary_id),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:journal_event_transaction_links, [:transaction_id], prefix: prefix))
    create(unique_index(:journal_event_transaction_links, [:journal_event_id], prefix: prefix))

    create(
      unique_index(:journal_event_transaction_links, [:transaction_id, :journal_event_id],
        prefix: prefix
      )
    )
  end

  defp create_journal_event_account_links(prefix) do
    create table(:journal_event_account_links, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(:journal_event_id, references(:journal_events, on_delete: :nothing, type: :binary_id),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:journal_event_account_links, [:account_id], prefix: prefix))
    create(unique_index(:journal_event_account_links, [:journal_event_id], prefix: prefix))

    create(
      unique_index(:journal_event_account_links, [:account_id, :journal_event_id], prefix: prefix)
    )
  end

  defp create_journal_event_command_links(prefix) do
    create table(:journal_event_command_links, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(:command_id, references(:commands, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(:journal_event_id, references(:journal_events, on_delete: :nothing, type: :binary_id),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:journal_event_command_links, [:command_id], prefix: prefix))
    create(unique_index(:journal_event_command_links, [:journal_event_id], prefix: prefix))

    create(
      unique_index(:journal_event_command_links, [:command_id, :journal_event_id], prefix: prefix)
    )
  end

  defp create_idempotency_keys(prefix) do
    create table(:idempotency_keys, primary_key: false, prefix: prefix) do
      add(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id),
        null: false
      )

      add(:key_hash, :binary, null: false)
      add(:first_seen_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:idempotency_keys, [:instance_id, :key_hash], prefix: prefix))
    create(index(:idempotency_keys, [:instance_id, :first_seen_at], prefix: prefix))
  end
end
