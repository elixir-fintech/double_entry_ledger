defmodule DoubleEntryLedger.DebitAccountTest do
  @moduledoc """
  This module contains test cases for debit accounts
  """
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Account

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  describe "Debit Account update balances [:posted]: " do
    setup [:create_instance]

    test "first debit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id)
      entry = %{type: :debit, amount: Money.new(200, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 200,
          posted: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 200, debit: 200}}
        },
      } = Account.update_balances(account, %{entry: entry, trx: :posted } )
    end

    test "debit entry with previous balance", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id, posted: %{amount: 100, debit: 100, credit: 0}, available: 100)
      entry = %{type: :debit, amount: Money.new(200, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 300,
          posted: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 300, debit: 300}}
        },
      } = Account.update_balances(account, %{entry: entry, trx: :posted } )
    end

    test "first credit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id)
      entry = %{type: :credit, amount: Money.new(200, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{posted: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: -200, credit: 200} } },
      } = Account.update_balances(account, %{entry: entry, trx: :posted } )
    end

    test "credit entry with previous balance", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id, posted: %{amount: 100, debit: 100, credit: 0}, available: 100)
      entry = %{type: :credit, amount: Money.new(50, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{available: 50, posted: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 50, credit: 50} } },
      } = Account.update_balances(account, %{entry: entry, trx: :posted } )
    end
  end

  describe "Debit Account update balances [:pending]: " do
    setup [:create_instance]

    test "first debit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id)
      entry = %{type: :debit, amount: Money.new(200, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: -200, debit: 200} } },
      } = Account.update_balances(account, %{entry: entry, trx: :pending } )
    end

    test "debit entry with previous balance", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id,
        posted: %{amount: 100, debit: 100, credit: 0}, pending: %{amount: -50, debit: 50, credit: 0 } , available: 100)
      entry = %{type: :debit, amount: Money.new(25, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 100,
          pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: -75 , debit: 75}}
        }
      } = Account.update_balances(account, %{entry: entry, trx: :pending } )
    end

    test "first credit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id)
      entry = %{type: :credit, amount: Money.new(200, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 200, credit: 200} } },
      } = Account.update_balances(account, %{entry: entry, trx: :pending } )
    end

    test "credit entry with previous balance", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id,
        posted: %{amount: 100, debit: 100, credit: 0}, pending: %{amount: 50, debit: 0, credit: 50 } , available: 50)
      entry = %{type: :credit, amount: Money.new(25, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 25,
          pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 75 , credit: 75}}
        }
      } = Account.update_balances(account, %{entry: entry, trx: :pending } )
    end
  end

  describe "Debit Account update balances [:pending_to_posted]: " do
    setup [:create_instance]

    test "debit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id,
        posted: %{amount: 100, debit: 100, credit: 0}, pending: %{amount: -50, debit: 50, credit: 0 }, available: 100 )
      entry = %{type: :debit, amount: Money.new(25, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 125,
          pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: -25, debit: 25} },
          posted: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 125, debit: 125} }
        },
      } = Account.update_balances(account, %{entry: entry, trx: :pending_to_posted } )
    end

    test "credit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id,
        posted: %{amount: 100, debit: 100, credit: 0}, pending: %{amount: 50, debit: 0, credit: 50 }, available: 50 )
      entry = %{type: :credit, amount: Money.new(25, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 50,
          pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 25, credit: 25} },
          posted: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 75, credit: 25} }
        },
      } = Account.update_balances(account, %{entry: entry, trx: :pending_to_posted } )
    end
  end

  describe "Debit Account update balances [:pending_to_archived]: " do
    setup [:create_instance]

    test "debit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id,
        posted: %{amount: 100, debit: 100, credit: 0}, pending: %{amount: -50, debit: 50, credit: 0 }, available: 100 )
      entry = %{type: :debit, amount: Money.new(25, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 100,
          pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: -25, debit: 25} }
        },
      } = Account.update_balances(account, %{entry: entry, trx: :pending_to_archived } )
    end

    test "credit entry", %{instance: inst} do
      account = account_fixture(type: :debit, instance_id: inst.id,
        posted: %{amount: 100, debit: 100, credit: 0}, pending: %{amount: 50, debit: 0, credit: 50 }, available: 50 )
      entry = %{type: :credit, amount: Money.new(25, :EUR) }
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          available: 75,
          pending: %Ecto.Changeset{action: :insert, valid?: true, changes: %{amount: 25, credit: 25} }
        },
      } = Account.update_balances(account, %{entry: entry, trx: :pending_to_archived } )
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end
end
