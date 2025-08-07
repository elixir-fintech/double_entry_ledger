defmodule DoubleEntryLedger.TransactionTest do
  @moduledoc """
  This module defines tests for the transaction
  """
  use DoubleEntryLedger.RepoCase
  alias DoubleEntryLedger.{Transaction, TransactionStore}
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.TransactionFixtures
  import Ecto.Query, only: [from: 2]

  doctest Transaction

  describe "validate_accounts/1" do
    setup [:create_instance, :create_accounts]

    test "no entries", %{instance: inst} do
      attr = transaction_attr(instance_id: inst.id)
      changeset = Transaction.changeset(%Transaction{}, attr)
      assert {"must have at least 2 entries", []} = Keyword.get(changeset.errors, :entry_count)
    end

    test "one account on a different ledgers", ctx do
      instance2 = instance_fixture()
      a1 = account_fixture(instance_id: ctx.instance.id, type: :asset)
      a2 = account_fixture(instance_id: instance2.id, type: :liability, normal_balance: :credit)

      attr =
        transaction_attr(
          instance_id: ctx.instance.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"accounts must be on same ledger", []} = Keyword.get(&1.errors, :account_id)
      )
      |> then(&assert length(&1) == 2)
    end

    test "all accounts on different ledgers", ctx do
      instance2 = instance_fixture()
      a1 = account_fixture(instance_id: ctx.instance.id, type: :asset)

      a2 =
        account_fixture(instance_id: ctx.instance.id, type: :liability, normal_balance: :credit)

      attr =
        transaction_attr(
          instance_id: instance2.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"accounts must be on same ledger", []} = Keyword.get(&1.errors, :account_id)
      )
      |> then(&assert length(&1) == 2)
    end
  end

  describe "validate_entry_count/1" do
    setup [:create_instance, :create_accounts]

    test "empty entries", ctx do
      attr = transaction_attr(instance_id: ctx.instance.id, entries: [])
      changeset = Transaction.changeset(%Transaction{}, attr)
      assert {"must have at least 2 entries", []} = Keyword.get(changeset.errors, :entry_count)
    end

    test "one entry", %{instance: inst, accounts: [acc1, _, _, _]} do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id}
          ]
        )

      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 entry_count: {"must have at least 2 entries", []}
               ]
             } = Transaction.changeset(%Transaction{}, attr)
    end

    test "one entry also adds error to entry account id", %{
      instance: inst,
      accounts: [acc1, _, _, _]
    } do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"at least 2 accounts are required", []} = Keyword.get(&1.errors, :account_id)
      )
      |> then(&assert length(&1) == 1)
    end
  end

  describe "validate_debit_equals_credit_per_currency/1" do
    setup [:create_instance, :create_accounts]

    test "both debit entries", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"must have equal debit and credit", []} = Keyword.get(&1.errors, :value)
      )
      |> then(&assert length(&1) == 2)
    end

    test "both credit entries", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"must have equal debit and credit", []} = Keyword.get(&1.errors, :value)
      )
      |> then(&assert length(&1) == 2)
    end

    test "amount different", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(101, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"must have equal debit and credit", []} = Keyword.get(&1.errors, :value)
      )
      |> then(&assert length(&1) == 2)
    end

    test "amount different, also add :amount error for TransactionEventMap use", %{
      instance: inst,
      accounts: [acc1, acc2, _, _]
    } do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(101, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"must have equal debit and credit", []} = Keyword.get(&1.errors, :amount)
      )
      |> then(&assert length(&1) == 2)
    end

    test "same amount", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      assert Transaction.changeset(%Transaction{}, attr).valid?
    end
  end

  describe "validate_currency/1" do
    setup [:create_instance, :create_accounts]

    test "same amount but different currency", %{instance: inst} do
      acc1 = account_fixture(instance_id: inst.id, type: :asset, currency: :EUR)

      acc2 =
        account_fixture(
          instance_id: inst.id,
          type: :liability,
          normal_balance: :credit,
          currency: :USD
        )

      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      changeset = Transaction.changeset(%Transaction{}, attr)
      assert changeset.valid? == false

      invalid_entry_changeset =
        get_assoc(changeset, :entries, :changeset)
        |> Enum.find(&(&1.valid? == false))

      assert {"account (USD) must be equal to entry (EUR)", []} =
               Keyword.get(invalid_entry_changeset.errors, :currency)
    end

    test "same amounts in different currencies", %{instance: inst} do
      acc1 = account_fixture(instance_id: inst.id, type: :asset, currency: :EUR)

      acc2 =
        account_fixture(
          instance_id: inst.id,
          type: :liability,
          normal_balance: :credit,
          currency: :USD
        )

      acc3 =
        account_fixture(
          instance_id: inst.id,
          type: :liability,
          normal_balance: :credit,
          currency: :EUR
        )

      acc4 = account_fixture(instance_id: inst.id, type: :asset, currency: :USD)

      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(50, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :USD), account_id: acc2.id},
            %{type: :credit, value: Money.new(50, :EUR), account_id: acc3.id},
            %{type: :debit, value: Money.new(100, :USD), account_id: acc4.id}
          ]
        )

      assert %Ecto.Changeset{
               valid?: true,
               errors: []
             } = Transaction.changeset(%Transaction{}, attr)
    end

    test "currency entry != currency account", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :USD), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :USD), account_id: acc2.id}
          ]
        )

      Transaction.changeset(%Transaction{}, attr)
      |> get_assoc(:entries, :changeset)
      |> Enum.map(
        &assert {"account (EUR) must be equal to entry (USD)", []} =
                  Keyword.get(&1.errors, :currency)
      )
      |> then(&assert length(&1) == 2)
    end
  end

  describe "validate_posted_state_transition/1" do
    setup [:create_instance, :create_accounts]

    test "pending to posted", ctx do
      %{transaction: trx} = create_pending_transaction(ctx)

      assert %Ecto.Changeset{
               valid?: true,
               errors: [],
               changes: %{
                 status: :posted,
                 posted_at: _
               }
             } = Transaction.changeset(trx, %{status: :posted})
    end

    test "posted to pending or archived", ctx do
      %{transaction: trx} = create_posted_transaction(ctx)

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
      %{transaction: trx} = create_pending_transaction(ctx)

      assert %Ecto.Changeset{
               valid?: true,
               errors: []
             } = Transaction.changeset(trx, %{status: :archived})
    end

    test "archived to pending or posted", ctx do
      %{transaction: %{id: id}} = create_pending_transaction(ctx)
      from(t in Transaction, where: t.id == ^id) |> Repo.update_all(set: [status: :archived])
      trx = TransactionStore.get_by_id(id)

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
      attr =
        transaction_attr(
          status: :archived,
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 status:
                   {"cannot create :archived transactions, must be transitioned from :pending",
                    []}
               ]
             } = Transaction.changeset(%Transaction{}, attr)
    end
  end

  describe "update_posted_at" do
    setup [:create_instance, :create_accounts]

    test "update posted_at for posted", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          status: :posted,
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      assert %Ecto.Changeset{
               valid?: true,
               errors: [],
               changes: %{
                 posted_at: _
               }
             } = Transaction.changeset(%Transaction{}, attr)
    end

    test "update posted_at for pending to posted", ctx do
      %{transaction: trx} = create_pending_transaction(ctx)

      assert %Ecto.Changeset{
               valid?: true,
               errors: [],
               changes: %{
                 posted_at: _
               }
             } = Transaction.changeset(trx, %{status: :posted})
    end

    test "is not updating for pending", %{instance: inst, accounts: [acc1, acc2, _, _]} do
      attr =
        transaction_attr(
          status: :pending,
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: acc1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: acc2.id}
          ]
        )

      cs = Transaction.changeset(%Transaction{}, attr)
      assert !Map.has_key?(cs.changes, :posted_at)
    end
  end
end
