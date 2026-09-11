defmodule DoubleEntryLedger.Migration.V5 do
  @moduledoc """
  Version 5 — the v0.5.0 schema change.

  Takes a version 4 schema (the v0.4.0 release) directly to the v0.5.0 schema.
  It declares the end state rather than replaying the intermediate steps this
  change went through while it was unreleased, but every step that touches
  existing rows is preserved so a consumer upgrading from 0.4.x with data in
  the tables ends up with the same contents as an empty install.

  In order, `up/1`:

    1. Collapses the three `journal_event_*_links` join tables into direct
       nullable FK columns on `journal_events` (`command_id`,
       `transaction_id`, `account_id`), backfilling from the link tables
       before dropping them. Removes one background job per command and three
       rows of write amplification. The XOR invariant ("a journal event is
       either a transaction event or an account event, never both") is
       enforced by a `transaction_xor_account` CHECK constraint that allows
       the post-deletion `(NULL, NULL)` state, since commands and accounts are
       deletable.
    2. Denormalizes `instance_id` onto `command_queue_items` (backfilled from
       `commands`, then `NOT NULL`). Removes the O(N²) drain pattern where
       `find_next_command` scanned all already-`:processed` rows to find the
       next in-flight item.
    3. Widens `accounts.available`, `accounts.negative_limit`, and
       `balance_history_entries.available` from `integer` to `bigint` so
       balances stored in minor units are not limited to 32-bit values.
    4. Adds a database-generated `command_queue_items.queue_position` for
       stable command ordering, backfills existing rows in
       `(inserted_at, command_id)` order, and creates the partial in-flight
       index `(instance_id, queue_position)` that command selection uses.
    5. Adds the transient `command_queue_items.retry_delay_seconds` column
       plus the CHECK constraint that keeps it `NULL` at rest.
    6. Generates command insertion and command-queue insertion, update, and
       processing timestamps from the PostgreSQL clock, and installs the queue
       trigger that stamps them and converts `retry_delay_seconds` into a
       `next_retry_after` deadline on the database clock.

  `down/1` reverses all of it back to the version 4 schema.
  """

  use DoubleEntryLedger.Migration.Version

  @doc "Migrates a version 4 schema to version 5."
  @spec up(String.t()) :: :ok
  def up(prefix \\ default_prefix()) do
    link_journal_events_directly(prefix)
    denormalize_queue_instance_id(prefix)
    widen_balance_columns(prefix)
    add_queue_position(prefix)
    add_retry_delay_seconds(prefix)
    generate_timestamps_in_postgres(prefix)

    :ok
  end

  @doc "Rolls a version 5 schema back to version 4."
  @spec down(String.t()) :: :ok
  def down(prefix \\ default_prefix()) do
    restore_application_timestamps(prefix)
    remove_retry_delay_seconds(prefix)
    remove_queue_position(prefix)
    narrow_balance_columns(prefix)
    remove_queue_instance_id(prefix)
    restore_journal_event_links(prefix)

    :ok
  end

  # ── Direct journal event foreign keys ──────────────────────────────

  defp link_journal_events_directly(prefix) do
    # 1. Add nullable FK columns. command_id and account_id are nilified on
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

  defp restore_journal_event_links(prefix) do
    # 1. Recreate the link tables with the version 4 schema shape.
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

  # ── Denormalized queue instance_id ─────────────────────────────────

  defp denormalize_queue_instance_id(prefix) do
    alter table(:command_queue_items, prefix: prefix) do
      add(:instance_id, references(:instances, on_delete: :nothing, type: :binary_id))
    end

    flush()

    execute("""
    UPDATE #{prefix}.command_queue_items eqi
    SET instance_id = c.instance_id
    FROM #{prefix}.commands c
    WHERE c.id = eqi.command_id
    """)

    flush()

    # Enforce NOT NULL via raw SQL because `modify/3` with a `references/2`
    # definition tries to re-create the FK constraint added above.
    execute("ALTER TABLE #{prefix}.command_queue_items ALTER COLUMN instance_id SET NOT NULL")
  end

  defp remove_queue_instance_id(prefix) do
    alter table(:command_queue_items, prefix: prefix) do
      remove(:instance_id)
    end
  end

  # ── Bigint balance and limit columns ───────────────────────────────
  #
  # `accounts.available`, `accounts.negative_limit`, and
  # `balance_history_entries.available` were `int4` (max 2,147,483,647).
  # That caps balances at ~$21M when amounts are stored in cents and
  # less for finer-grained currencies — easy to hit on high-volume
  # merchant or treasury accounts. JSONB-stored balances
  # (`accounts.posted`, `accounts.pending`, etc.) are already unbounded
  # because JSON numbers are arbitrary precision.
  #
  # Postgres ≥ 14 treats `integer → bigint` ALTER COLUMN TYPE as
  # metadata-only (no row rewrite), so this is fast on large tables.

  defp widen_balance_columns(prefix) do
    alter table(:accounts, prefix: prefix) do
      modify(:available, :bigint, from: :integer)
      modify(:negative_limit, :bigint, from: :integer)
    end

    alter table(:balance_history_entries, prefix: prefix) do
      modify(:available, :bigint, from: :integer)
    end
  end

  defp narrow_balance_columns(prefix) do
    alter table(:balance_history_entries, prefix: prefix) do
      modify(:available, :integer, from: :bigint)
    end

    alter table(:accounts, prefix: prefix) do
      modify(:negative_limit, :integer, from: :bigint)
      modify(:available, :integer, from: :bigint)
    end
  end

  # ── Stable database-generated queue positions ──────────────────────

  defp add_queue_position(prefix) do
    sequence = queue_position_sequence(prefix)

    execute("CREATE SEQUENCE #{sequence} AS bigint")

    alter table(:command_queue_items, prefix: prefix) do
      add(:queue_position, :bigint)
    end

    flush()

    execute(
      "ALTER SEQUENCE #{sequence} " <>
        "OWNED BY #{prefix}.command_queue_items.queue_position"
    )

    execute("""
    WITH ordered AS (
      SELECT id, row_number() OVER (ORDER BY inserted_at, command_id) AS queue_position
      FROM #{prefix}.command_queue_items
    )
    UPDATE #{prefix}.command_queue_items AS queue_item
    SET queue_position = ordered.queue_position
    FROM ordered
    WHERE queue_item.id = ordered.id
    """)

    execute("""
    SELECT setval(
      '#{sequence}',
      COALESCE((SELECT MAX(queue_position) FROM #{prefix}.command_queue_items), 0) + 1,
      false
    )
    """)

    execute(
      "ALTER TABLE #{prefix}.command_queue_items " <>
        "ALTER COLUMN queue_position SET DEFAULT nextval('#{sequence}')"
    )

    execute(
      "ALTER TABLE #{prefix}.command_queue_items " <>
        "ALTER COLUMN queue_position SET NOT NULL"
    )

    # The in-flight index carries only currently-in-flight queue items and is
    # ordered by (instance, queue position), which is exactly the access
    # pattern of InstanceProcessor's find_next_command query.
    create(in_flight_index(prefix))
  end

  defp remove_queue_position(prefix) do
    drop(in_flight_index(prefix))

    # Dropping the column also drops the sequence it owns.
    alter table(:command_queue_items, prefix: prefix) do
      remove(:queue_position)
    end
  end

  defp queue_position_sequence(prefix) do
    "#{prefix}.command_queue_items_queue_position_seq"
  end

  defp in_flight_index(prefix) do
    index(:command_queue_items, [:instance_id, :queue_position],
      prefix: prefix,
      where: "status IN ('pending', 'occ_timeout', 'failed')",
      name: "idx_command_queue_items_in_flight"
    )
  end

  # ── Transient retry delay instruction ──────────────────────────────
  #
  # `retry_delay_seconds` is a transient instruction to the queue trigger,
  # not persisted state: a writer sets it instead of computing
  # `next_retry_after` on the application clock, the BEFORE UPDATE trigger
  # turns it into `database_now + delay` and resets the column to NULL in
  # the same row write. Because the trigger is FOR EACH ROW it applies to
  # single-row changesets and bulk UPDATEs alike. The trigger only fires on
  # UPDATE, so a CHECK constraint enforces the invariant for inserts as well:
  # CHECK constraints are evaluated after BEFORE ROW triggers, which lets the
  # UPDATE path pass (the trigger has already cleared the column) while a
  # direct INSERT that supplies a delay is rejected. The column is therefore
  # always NULL at rest.

  defp add_retry_delay_seconds(prefix) do
    alter table(:command_queue_items, prefix: prefix) do
      add(:retry_delay_seconds, :integer)
    end

    create(
      constraint(:command_queue_items, :command_queue_items_retry_delay_seconds_transient,
        check: "retry_delay_seconds IS NULL",
        prefix: prefix
      )
    )
  end

  defp remove_retry_delay_seconds(prefix) do
    drop(
      constraint(:command_queue_items, :command_queue_items_retry_delay_seconds_transient,
        prefix: prefix
      )
    )

    alter table(:command_queue_items, prefix: prefix) do
      remove(:retry_delay_seconds)
    end
  end

  # ── PostgreSQL-generated command and queue timestamps ──────────────

  defp generate_timestamps_in_postgres(prefix) do
    execute(
      "ALTER TABLE #{prefix}.commands " <>
        "ALTER COLUMN inserted_at SET DEFAULT timezone('UTC', statement_timestamp())"
    )

    execute(
      "ALTER TABLE #{prefix}.command_queue_items " <>
        "ALTER COLUMN inserted_at SET DEFAULT timezone('UTC', statement_timestamp())"
    )

    execute(
      "ALTER TABLE #{prefix}.command_queue_items " <>
        "ALTER COLUMN updated_at SET DEFAULT timezone('UTC', statement_timestamp())"
    )

    execute("""
    CREATE FUNCTION #{prefix}.set_command_queue_item_timestamps()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      database_now timestamp without time zone := timezone('UTC', statement_timestamp());
    BEGIN
      NEW.updated_at = database_now;

      IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NEW.status = 'processing' THEN
          NEW.processing_started_at = database_now;
          NEW.processing_completed_at = NULL;
        ELSIF NEW.status IN ('processed', 'failed', 'occ_timeout', 'dead_letter') THEN
          NEW.processing_completed_at = database_now;
        END IF;
      END IF;

      -- retry_delay_seconds is a transient instruction: convert it into a
      -- deadline on the database clock and clear it so it is never stored.
      IF NEW.retry_delay_seconds IS NOT NULL THEN
        NEW.next_retry_after = database_now + make_interval(secs => NEW.retry_delay_seconds);
        NEW.retry_delay_seconds = NULL;
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    flush()

    execute("""
    CREATE TRIGGER command_queue_items_set_timestamps
    BEFORE UPDATE ON #{prefix}.command_queue_items
    FOR EACH ROW
    EXECUTE FUNCTION #{prefix}.set_command_queue_item_timestamps()
    """)
  end

  defp restore_application_timestamps(prefix) do
    execute(
      "DROP TRIGGER command_queue_items_set_timestamps " <>
        "ON #{prefix}.command_queue_items"
    )

    execute("DROP FUNCTION #{prefix}.set_command_queue_item_timestamps()")

    execute("ALTER TABLE #{prefix}.command_queue_items ALTER COLUMN updated_at DROP DEFAULT")

    execute("ALTER TABLE #{prefix}.command_queue_items ALTER COLUMN inserted_at DROP DEFAULT")

    execute("ALTER TABLE #{prefix}.commands ALTER COLUMN inserted_at DROP DEFAULT")
  end

  # ── Version 4 link table definitions ───────────────────────────────
  #
  # These duplicate `DoubleEntryLedger.Migration.V1`'s helpers, and the
  # duplication is deliberate. Versions 2, 3 and 4 happen not to touch the link
  # tables (V2 alters `accounts` and `transactions`, V3 adds a `commands`
  # column, V4 swaps a `balance_history_entries` index), so V1's DDL and the
  # version 4 shape are byte-for-byte identical today — calling V1's helpers
  # from here would emit the same SQL.
  #
  # It is still the wrong dependency to create. What V1 emits is "the tables
  # version 1 introduces"; what this rollback needs is "the tables as they
  # stood at version 4". They coincide only by accident of which versions
  # happened to alter them. Sharing would make any future reorganisation of
  # V1's DDL silently change what a version 5 → 4 rollback produces, turning an
  # edit to one released version into a corrupt rollback target for another.
  # Each version module owns the exact shape of the schema it was written
  # against and stays frozen.

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
end
