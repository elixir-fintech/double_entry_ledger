defmodule DoubleEntryLedger.Repo.Migrations.AddNegativeLimitToAccounts do
  use Ecto.Migration

  @schema_prefix Application.compile_env(:double_entry_ledger, :schema_prefix)
  # Max int32 — used as "unlimited" for accounts that had allowed_negative: true
  @max_int32 2_147_483_647

  def up do
    alter table(:accounts, prefix: @schema_prefix) do
      add :negative_limit, :integer, null: false, default: 0
    end

    flush()

    # Migrate existing allowed_negative: true accounts to unlimited negative limit
    execute """
    UPDATE #{@schema_prefix}.accounts
    SET negative_limit = #{@max_int32}
    WHERE allowed_negative = true
    """

    alter table(:accounts, prefix: @schema_prefix) do
      remove :allowed_negative
    end
  end

  def down do
    alter table(:accounts, prefix: @schema_prefix) do
      add :allowed_negative, :boolean, null: false, default: false
    end

    flush()

    execute """
    UPDATE #{@schema_prefix}.accounts
    SET allowed_negative = true
    WHERE negative_limit > 0
    """

    alter table(:accounts, prefix: @schema_prefix) do
      remove :negative_limit
    end
  end
end
