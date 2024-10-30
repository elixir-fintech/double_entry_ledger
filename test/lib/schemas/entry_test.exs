defmodule DoubleEntryLedger.EntryTest do
  @moduledoc """
  Tests for the Entry schema.
  """

  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Entry, Repo, TransactionStore}

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.TransactionFixtures

  describe "changeset" do
    setup [:create_instance, :create_account]

    test "returns error changeset for missing fields", _ctx do
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          type: {"can't be blank", [validation: :required]},
          value: {"can't be blank", [validation: :required]},
          account_id: {"can't be blank", [validation: :required]}
        ]
      } = Entry.changeset(%Entry{}, %{}, :pending)
    end

    # validation allows empty transaction_id, but must be present in db
    # Entries must have a transaction_id, and transaction must have at least 2 entries
    test "raises not-null constraint error for missing transaction_id", ctx do
      attr = entry_attr(account_id: ctx.account.id)
      assert_raise Postgrex.Error,
        ~r/"transaction_id" of relation "entries" violates not-null constraint/,
        fn -> Repo.insert(Entry.changeset(%Entry{}, attr, :pending)) end
    end
  end

  describe "update_changeset/2" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "returns valid changeset with update to account", %{transaction: %{entries: [e0, _]}}  do
      assert %Ecto.Changeset{
        valid?: true,
        changes: %{
          account: _,
          value: %Money{amount: 50, currency: :EUR},
        }
      } = Entry.update_changeset(e0, %{value: Money.new(50, :EUR)}, :pending_to_posted)
    end

    test "returns error changeset for missing value", %{transaction: %{entries: [e0, _]}} do
      assert %Ecto.Changeset{
        valid?: false,
        errors: [value: {"is invalid", [type: Money.Ecto.Composite.Type, validation: :cast]}]
      } = Entry.update_changeset(e0, %{value: %{}}, :pending_to_posted)
    end
  end

  describe "validate_same_account_currency/1" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "returns error changeset for different currency", %{transaction: %{entries: [e0, _]}} do
      assert %Ecto.Changeset{
        valid?: false,
        errors: [account: {"currency (EUR) must be equal to entry currency (USD)", []}]
      } = Entry.update_changeset(e0, %{value: Money.new(100, :USD)}, :pending_to_posted)
    end
  end

  defp create_instance(_ctx) do
    %{instance: instance_fixture()}
  end

  defp create_account(ctx) do
    %{account: account_fixture(instance_id: ctx.instance.id)}
  end

  defp entry_attr(attrs) do
      attrs
      |> Enum.into(%{
        value: Money.new(100, :EUR),
        type: :debit
      })
  end

  defp create_transaction(%{instance: instance, accounts: [a1, a2, _, _]}) do
    transaction = transaction_attr(status: :pending,
      instance_id: instance.id, entries: [
        %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
        %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
      ])
    {:ok, trx} = TransactionStore.create(transaction)
    %{transaction: trx}
  end
end
