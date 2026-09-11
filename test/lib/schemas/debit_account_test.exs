defmodule DoubleEntryLedger.DebitAccountTest do
  @moduledoc """
  This module contains test cases for debit accounts
  """
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Account, Entry}

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  describe "Debit Account update balances [:posted]: " do
    setup [:create_instance]

    test "first debit entry", %{instance: inst} do
      account = account_fixture(normal_balance: :debit, instance_id: inst.id)
      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(200, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 200,
                 posted: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 200, debit: 200}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "debit entry with previous balance", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          available: 100
        )

      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(200, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 300,
                 posted: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 300, debit: 300}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "first credit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          negative_limit: 2_147_483_647
        )

      entry = %Entry{account_id: account.id, type: :credit, value: Money.new(200, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 posted: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: -200, credit: 200}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry with previous balance", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          available: 100
        )

      entry = %Entry{account_id: account.id, type: :credit, value: Money.new(50, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 50,
                 posted: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 50, credit: 50}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end
  end

  describe "Debit Account update balances [:pending]: " do
    setup [:create_instance]

    test "first debit entry", %{instance: inst} do
      account = account_fixture(normal_balance: :debit, instance_id: inst.id)
      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(200, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 200, debit: 200}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "debit entry with previous balance", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: 50, debit: 50, credit: 0},
          available: 100
        )

      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(25, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 100,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 75, debit: 75}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "first credit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          negative_limit: 2_147_483_647
        )

      entry = %Entry{account_id: account.id, type: :credit, value: Money.new(200, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: -200, credit: 200}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "credit entry with previous balance", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: -50, debit: 0, credit: 50},
          available: 50
        )

      entry = %Entry{account_id: account.id, type: :credit, value: Money.new(25, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 25,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: -75, credit: 75}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "Debit Account update balances [:pending_to_posted]: " do
    setup [:create_instance]

    test "debit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: 50, debit: 50, credit: 0},
          available: 100
        )

      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(25, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 125,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 25, debit: 25}
                 },
                 posted: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 125, debit: 125}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending_to_posted})
    end

    test "credit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: -50, debit: 0, credit: 50},
          available: 50
        )

      entry = %Entry{account_id: account.id, type: :credit, value: Money.new(25, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 50,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: -25, credit: 25}
                 },
                 posted: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 75, credit: 25}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending_to_posted})
    end
  end

  describe "Debit Account update balances [:pending_to_pending]: " do
    setup [:create_instance]

    test "debit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: 50, debit: 50, credit: 0},
          available: 100
        )

      entry =
        Entry.changeset(
          %Entry{account_id: account.id, type: :debit, value: Money.new(25, :EUR)},
          %{value: Money.new(10, :EUR)}
        )

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 100,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 35, debit: 35}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending_to_pending})
    end

    test "credit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: -50, debit: 0, credit: 50},
          available: 50
        )

      entry =
        Entry.changeset(
          %Entry{account_id: account.id, type: :credit, value: Money.new(25, :EUR)},
          %{value: Money.new(10, :EUR)}
        )

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 65,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: -35, credit: 35}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending_to_pending})
    end
  end

  describe "Debit Account update balances [:pending_to_archived]: " do
    setup [:create_instance]

    test "debit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: 50, debit: 50, credit: 0},
          available: 100
        )

      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(25, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 100,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 25, debit: 25}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending_to_archived})
    end

    test "credit entry", %{instance: inst} do
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: -50, debit: 0, credit: 50},
          available: 50
        )

      entry = %Entry{account_id: account.id, type: :credit, value: Money.new(25, :EUR)}

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 75,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: -25, credit: 25}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending_to_archived})
    end

    test "reverses by the ORIGINAL pending amount, not the payload's new value", %{instance: inst} do
      # Regression test for the :pending_to_archived bug where legacy
      # `Account.update/4` reads `get_field(entry, :value)` (the NEW value
      # cast from the update payload) instead of `entry.data.value`
      # (the original pending amount).
      #
      # Existing tests pass plain %Entry{} structs, so update_balances/2
      # wraps them in `Entry.changeset(entry, %{})` with no changes —
      # `get_field` returns data.value and the bug doesn't manifest.
      # Production hits the bug because `Entry.update_changeset/3` calls
      # `cast(attrs, [:value])` to apply the new value as a change.
      account =
        account_fixture(
          normal_balance: :debit,
          instance_id: inst.id,
          posted: %{amount: 100, debit: 100, credit: 0},
          pending: %{amount: 50, debit: 50, credit: 0},
          available: 50
        )

      entry = %Entry{account_id: account.id, type: :debit, value: Money.new(50, :EUR)}

      entry_changeset =
        entry
        |> Ecto.Changeset.cast(%{value: %{amount: 30, currency: :EUR}}, [:value])

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 100,
                 pending: %Ecto.Changeset{
                   action: :insert,
                   valid?: true,
                   changes: %{amount: 0, debit: 0}
                 }
               }
             } =
               Account.update_balances(account, %{
                 entry: entry_changeset,
                 trx: :pending_to_archived
               })
    end
  end
end
