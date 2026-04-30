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
    * Version 5 — collapse the three `journal_event_*_links` join tables into
      direct nullable FK columns on `journal_events` (`command_id`,
      `transaction_id`, `account_id`). Removes one synchronous Oban job per
      command and three rows of write amplification. The XOR invariant
      ("a journal event is either a transaction event or an account event,
      never both") is enforced by a `transaction_xor_account` CHECK constraint
      that allows the post-deletion `(NULL, NULL)` state since commands and
      accounts are deletable.
    * Version 6 — denormalize `instance_id` onto `command_queue_items` and
      add a partial index `(instance_id, inserted_at) WHERE status IN
      ('pending', 'occ_timeout', 'failed')`. Removes the O(N²) drain pattern
      where `find_next_command` scanned all already-`:processed` rows in
      `inserted_at` order to find the next in-flight item. The new index
      contains only in-flight rows (tiny in steady state) and is partitioned
      by instance for multi-instance correctness.

  New consumers add a single migration calling `up()` / `down()` — all versions
  apply in order. Existing consumers upgrading to a new library release add a
  new migration per upgrade, using `:from` to skip already-applied versions:

      # Upgrade from v0.1.0 (version 1 already applied)
      def up, do: DoubleEntryLedger.Migration.up(from: 1)
      def down, do: DoubleEntryLedger.Migration.down(version: 1)

      # Upgrade from 0.3.x to 0.4.0 (versions 1-3 already applied)
      def up, do: DoubleEntryLedger.Migration.up(from: 3)
      def down, do: DoubleEntryLedger.Migration.down(from: 4, version: 3)

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

  @latest_version 6

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

    if from < 4 and version >= 4 do
      v4_up(prefix)
      flush()
    end

    if from < 5 and version >= 5 do
      v5_up(prefix)
      flush()
    end

    if from < 6 and version >= 6, do: v6_up(prefix)

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

    if from >= 6 and version < 6 do
      v6_down(prefix)
      flush()
    end

    if from >= 5 and version < 5 do
      v5_down(prefix)
      flush()
    end

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

  # ── Version 5: collapse journal_event_*_links into direct FKs on journal_events ──

  defp v5_up(prefix) do
    # 1. Add nullable FK columns. command_id and account_id are nullable on
    # delete because commands and accounts are deletable; journal_events
    # outlive them and surface NULL after the source is removed (matching
    # the previous on_delete: :delete_all behaviour of the link tables).
    alter table(:journal_events, prefix: prefix) do
      add(:command_id, references(:commands, on_delete: :nilify_all, type: :binary_id))

      add(
        :transaction_id,
        references(:transactions, on_delete: :nothing, type: :binary_id)
      )

      add(:account_id, references(:accounts, on_delete: :nilify_all, type: :binary_id))
    end

    flush()

    # 2. Backfill the new columns from the existing link tables. Rows whose
    # link was already cascade-deleted (e.g. the source account is gone)
    # remain NULL, matching post-deletion semantics.
    execute("""
    UPDATE #{prefix}.journal_events je
    SET command_id = l.command_id
    FROM #{prefix}.journal_event_command_links l
    WHERE l.journal_event_id = je.id
    """)

    execute("""
    UPDATE #{prefix}.journal_events je
    SET transaction_id = l.transaction_id
    FROM #{prefix}.journal_event_transaction_links l
    WHERE l.journal_event_id = je.id
    """)

    execute("""
    UPDATE #{prefix}.journal_events je
    SET account_id = l.account_id
    FROM #{prefix}.journal_event_account_links l
    WHERE l.journal_event_id = je.id
    """)

    flush()

    # 3. XOR-style invariant: at most one of (transaction_id, account_id).
    # The (NULL, NULL) state is allowed so that account deletion doesn't
    # break the constraint for previously-set account events.
    create(
      constraint(:journal_events, :transaction_xor_account,
        check: "NOT (transaction_id IS NOT NULL AND account_id IS NOT NULL)",
        prefix: prefix
      )
    )

    # 4. Indexes for the new FKs (mirrors what the link tables had).
    create(index(:journal_events, [:command_id], prefix: prefix))
    create(index(:journal_events, [:transaction_id], prefix: prefix))
    create(index(:journal_events, [:account_id], prefix: prefix))

    # 5. Drop the now-redundant link tables.
    drop(table(:journal_event_command_links, prefix: prefix))
    drop(table(:journal_event_transaction_links, prefix: prefix))
    drop(table(:journal_event_account_links, prefix: prefix))
  end

  defp v5_down(prefix) do
    # 1. Recreate the link tables with the original v1 schema shape.
    create_journal_event_transaction_links(prefix)
    create_journal_event_account_links(prefix)
    create_journal_event_command_links(prefix)

    flush()

    # 2. Backfill the link tables from the journal_events columns. Requires
    # PostgreSQL 13+ for `gen_random_uuid()`. NULL columns produce no row.
    execute("""
    INSERT INTO #{prefix}.journal_event_command_links
      (id, journal_event_id, command_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, command_id, NOW(), NOW()
    FROM #{prefix}.journal_events
    WHERE command_id IS NOT NULL
    """)

    execute("""
    INSERT INTO #{prefix}.journal_event_transaction_links
      (id, journal_event_id, transaction_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, transaction_id, NOW(), NOW()
    FROM #{prefix}.journal_events
    WHERE transaction_id IS NOT NULL
    """)

    execute("""
    INSERT INTO #{prefix}.journal_event_account_links
      (id, journal_event_id, account_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, account_id, NOW(), NOW()
    FROM #{prefix}.journal_events
    WHERE account_id IS NOT NULL
    """)

    flush()

    # 3. Drop indexes.
    drop(index(:journal_events, [:account_id], prefix: prefix))
    drop(index(:journal_events, [:transaction_id], prefix: prefix))
    drop(index(:journal_events, [:command_id], prefix: prefix))

    # 4. Drop the XOR check constraint.
    drop(constraint(:journal_events, :transaction_xor_account, prefix: prefix))

    # 5. Drop the columns.
    alter table(:journal_events, prefix: prefix) do
      remove(:account_id)
      remove(:transaction_id)
      remove(:command_id)
    end
  end

  # ── Version 6: denormalize instance_id onto command_queue_items + partial index ──

  defp v6_up(prefix) do
    # 1. Add nullable FK column to command_queue_items.
    alter table(:command_queue_items, prefix: prefix) do
      add(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id))
    end

    flush()

    # 2. Backfill from commands.
    execute("""
    UPDATE #{prefix}.command_queue_items eqi
    SET instance_id = c.instance_id
    FROM #{prefix}.commands c
    WHERE c.id = eqi.command_id
    """)

    flush()

    # 3. Enforce NOT NULL. Done via raw SQL because `modify/3` with a
    # `references/2` definition tries to re-create the FK constraint
    # we already added in step 1.
    execute("ALTER TABLE #{prefix}.command_queue_items ALTER COLUMN instance_id SET NOT NULL")

    # 4. Partial index keyed on (instance_id, inserted_at) for in-flight rows.
    # This is the index that fixes the O(N²) drain in InstanceProcessor's
    # find_next_command query — the index contains only currently-in-flight
    # queue items and is naturally ordered by (instance, inserted_at), which
    # is exactly the access pattern.
    create(
      index(:command_queue_items, [:instance_id, :inserted_at],
        prefix: prefix,
        where: "status IN ('pending', 'occ_timeout', 'failed')",
        name: "idx_command_queue_items_in_flight"
      )
    )
  end

  defp v6_down(prefix) do
    drop(
      index(:command_queue_items, [:instance_id, :inserted_at],
        prefix: prefix,
        name: "idx_command_queue_items_in_flight"
      )
    )

    alter table(:command_queue_items, prefix: prefix) do
      remove(:instance_id)
    end
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
