defmodule DoubleEntryLedger.Migration.V2 do
  @moduledoc """
  Version 2 — FK constraint fixes and `negative_limit`.

  Relaxes the `accounts` and `transactions` `instance_id` foreign keys from
  `:restrict` to `:nothing` (what Ecto emits by default) and replaces the
  boolean `accounts.allowed_negative` with the integer
  `accounts.negative_limit`, carrying existing rows across in both directions.
  """

  use DoubleEntryLedger.Migration.Version

  @max_int32 2_147_483_647

  @doc "Migrates a version 1 schema to version 2."
  @spec up(String.t()) :: :ok
  def up(prefix \\ default_prefix()) do
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

    :ok
  end

  @doc "Rolls a version 2 schema back to version 1."
  @spec down(String.t()) :: :ok
  def down(prefix \\ default_prefix()) do
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

    :ok
  end
end
