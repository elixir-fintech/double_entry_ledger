defmodule DoubleEntryLedger.TransactionTest do
  @moduledoc """
  This module defines tests for the transaction
  """
  use DoubleEntryLedger.RepoCase
  alias DoubleEntryLedger.{Transaction, TransactionStore}
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.TransactionFixtures

  doctest Transaction

  describe "validate_accounts/1" do
    setup [:create_instance, :create_accounts]

    test "no entries", %{instance: inst} do
      attr = transaction_attr(instance_id: inst.id)
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"no accounts found", []},
          entries: {"must have at least 2 entries", []},
        ]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "on account on a different ledgers", ctx do
      instance2 = instance_fixture()
      a1 = account_fixture(instance_id: ctx.instance.id, type: :debit)
      a2 = account_fixture(instance_id: instance2.id, type: :credit)
      attr = transaction_attr(instance_id: ctx.instance.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id:  a1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id:  a2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"accounts must be on same ledger", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "all accounts on different ledgers", ctx do
      instance2 = instance_fixture()
      a1 = account_fixture(instance_id: ctx.instance.id, type: :debit)
      a2 = account_fixture(instance_id: ctx.instance.id, type: :credit)
      attr = transaction_attr(instance_id: instance2.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"accounts must be on same ledger", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "validate_entries/1" do

    setup [:create_instance, :create_accounts]

    test "empty entries", ctx do
      attr = transaction_attr(instance_id: ctx.instance.id, entries: [])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"no accounts found", []},
          entries: {"must have at least 2 entries", []},
        ]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "one entry", %{instance: inst, accounts: [acc1, _, _, _]} do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id:  acc1.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have at least 2 entries", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "both debit entries", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :debit, value: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have equal debit and credit", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "both credit entries", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :credit, value: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have equal debit and credit", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "amount different", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(101, :EUR), account_id:  acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"must have equal debit and credit", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "same amount", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: true,
        errors: []
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "validate_currency/1" do
    setup [:create_instance, :create_accounts]

    test "same amount but different currency", %{instance: inst } do
      acc1 = account_fixture(instance_id: inst.id, type: :debit, currency: :EUR)
      acc2 = account_fixture(instance_id: inst.id, type: :credit, currency: :USD)
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id:  acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id:  acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"currency must be the same as account", []}]
     } = Transaction.changeset(%Transaction{}, attr)
    end


    test "same amounts in different currencies", %{instance: inst } do
      acc1 = account_fixture(instance_id: inst.id, type: :debit, currency: :EUR)
      acc2 = account_fixture(instance_id: inst.id, type: :credit, currency: :USD)
      acc3 = account_fixture(instance_id: inst.id, type: :debit, currency: :EUR)
      acc4 = account_fixture(instance_id: inst.id, type: :credit, currency: :USD)
      attr = transaction_attr(instance_id: inst.id, entries: [
         %{type: :debit, value: Money.new(50, :EUR), account_id:  acc1.id},
         %{type: :credit, value: Money.new(100, :USD), account_id:  acc2.id},
         %{type: :credit, value: Money.new(50, :EUR), account_id:  acc3.id},
         %{type: :debit, value: Money.new(100, :USD), account_id:  acc4.id}
      ])
      assert %Ecto.Changeset{
        valid?: true,
        errors: []
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "currency entry != currency account", %{instance: inst, accounts: [acc1, acc2, _, _] } do
      attr = transaction_attr(instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :USD), account_id: acc1.id},
        %{type: :credit, value: Money.new(100, :USD), account_id: acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          entries: {"currency must be the same as account", []}]
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "validate_posted_state_transition/1" do
    setup [:create_instance, :create_accounts]

    test "pending to posted", ctx do
      {:ok, trx} = create_transaction(ctx, :pending)
      assert %Ecto.Changeset{
        valid?: true,
        errors: [],
        changes: %{
          status: :posted,
          posted_at: _,
        }
      } = Transaction.changeset(trx, %{status: :posted})
    end

    test "posted to pending or archived", ctx do
      {:ok, trx} = create_transaction(ctx, :posted)
      assert %Ecto.Changeset{
        errors: [
          status: {"cannot update when in :posted state", []}
        ]
      } = Transaction.changeset(trx, %{status: :pending})
      assert %Ecto.Changeset{
        errors: [
          status: {"cannot update when in :posted state", []}
        ]
      } = Transaction.changeset(trx, %{status: :archived})
    end
  end

  describe "validate_archived_state_transition" do
    setup [:create_instance, :create_accounts]

    test "pending to archived", ctx do
      {:ok, trx} = create_transaction(ctx, :pending)
      assert %Ecto.Changeset{
        valid?: true,
        errors: []
      } = Transaction.changeset(trx, %{status: :archived})
    end

    test "archived to pending or posted", ctx do
      {:ok, trx} = create_transaction(ctx, :pending)
      {:ok, trx} = TransactionStore.update(trx, %{status: :archived})
      assert %Ecto.Changeset{
        errors: [
          status: {"cannot update when in :archived state", []}
        ]
      } = Transaction.changeset(trx, %{status: :pending})
      assert %Ecto.Changeset{
        errors: [
          status: {"cannot update when in :archived state", []}
        ]
      } = Transaction.changeset(trx, %{status: :posted})
    end

    test "can't create archived", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr = transaction_attr(status: :archived, instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          status: {"cannot create :archived transactions, must be transitioned from :pending", []}
        ]
      } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "update_posted_at" do
    setup [:create_instance, :create_accounts]

    test "update posted_at for posted", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr = transaction_attr(status: :posted, instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
      ])
      assert %Ecto.Changeset{
        valid?: true,
        errors: [],
        changes: %{
          posted_at: _,
        }
      } = Transaction.changeset(%Transaction{}, attr)
    end

    test "update posted_at for pending to posted", ctx do
      {:ok, trx} = create_transaction(ctx, :pending)
      assert %Ecto.Changeset{
        valid?: true,
        errors: [],
        changes: %{
          posted_at: _,
        }
      } = Transaction.changeset(trx, %{status: :posted})
    end

    test "is not updating for pending", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr = transaction_attr(status: :pending, instance_id: inst.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
      ])
      cs = Transaction.changeset(%Transaction{}, attr)
      assert !Map.has_key?(cs.changes, :posted_at)
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end

  defp create_transaction(%{instance: inst, accounts: [a1, a2, _, _ ]}, status) do
    attr = transaction_attr(status: status, instance_id: inst.id, entries: [
      %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
      %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
    ])
    TransactionStore.create(attr)
  end
end
