defmodule DoubleEntryLedger.EntryTest do
  @moduledoc """
  Tests for the Entry schema.
  """

  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Account, Entry, Repo, Balance}

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.TransactionFixtures

  doctest Entry

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

    test "returns valid changeset with update to account", %{transaction: %{entries: [e0, _]}} do
      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 account: _,
                 value: %Money{amount: 50, currency: :EUR}
               }
             } = Entry.update_changeset(e0, %{value: Money.new(50, :EUR)}, :pending_to_posted)
    end

    test "returns error changeset for missing value", %{transaction: %{entries: [e0, _]}} do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 value: {"is invalid", [type: Money.Ecto.Composite.Type, validation: :cast]}
               ]
             } = Entry.update_changeset(e0, %{value: %{}}, :pending_to_posted)
    end
  end

  describe "validate_same_account_currency/1" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "returns error changeset for different currency", %{transaction: %{entries: [e0, _]}} do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [currency: {"account (EUR) must be equal to entry (USD)", []}]
             } = Entry.update_changeset(e0, %{value: Money.new(100, :USD)}, :pending_to_posted)
    end
  end

  describe "put_balance_history_entry_assoc/1" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "balance history entry is created", %{transaction: %{entries: [e0, _]}} do
      %{balance_history_entries: [first | _t] = balance_history_entries} =
        account =
        Repo.get!(Account, e0.account_id, preload: [:balance_history_entries])
        |> Repo.preload([:balance_history_entries])

      assert 1 == length(balance_history_entries)
      assert first.account_id == e0.account_id
      assert first.entry_id == e0.id
      assert first.available == account.available
      assert first.posted == account.posted
      assert first.pending == account.pending
    end

    test "returns changeset with balance history entry", %{transaction: %{entries: entries}} do
      e0 = Enum.find(entries, fn e -> e.type == :credit end)
      changeset = Entry.update_changeset(e0, %{value: Money.new(100, :EUR)}, :pending_to_posted)

      [h, t | _] =
        balance_history_entries =
        Ecto.Changeset.get_assoc(changeset, :balance_history_entries, :struct)

      assert 2 = length(balance_history_entries)
      assert h.account_id == e0.account_id
      assert t.pending == %Balance{amount: 100, debit: 0, credit: 100}
      assert t.posted == %Balance{amount: 0, debit: 0, credit: 0}
      assert h.pending == %Balance{amount: 0, debit: 0, credit: 0}
      assert h.posted == %Balance{amount: 100, debit: 0, credit: 100}

      # not yet persisted
      assert h.entry_id == nil
    end
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
end
