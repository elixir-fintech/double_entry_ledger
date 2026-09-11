defmodule DoubleEntryLedger.Migration.V1 do
  @moduledoc """
  Version 1 — the initial schema (v0.1.0).

  `up/1` creates the package schema and every table it shipped with:
  `instances`, `accounts`, `transactions`, `entries`, `commands`,
  `command_queue_items`, `balance_history_entries`, `journal_events`,
  `pending_transaction_lookup`, the three `journal_event_*_links` join tables,
  and `idempotency_keys`.

  `down/1` drops them in reverse dependency order and then drops the schema
  itself.
  """

  use DoubleEntryLedger.Migration.Version

  @doc "Creates the version 1 schema."
  @spec up(String.t()) :: :ok
  def up(prefix \\ default_prefix()) do
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

    :ok
  end

  @doc "Drops the version 1 schema."
  @spec down(String.t()) :: :ok
  def down(prefix \\ default_prefix()) do
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

    :ok
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
