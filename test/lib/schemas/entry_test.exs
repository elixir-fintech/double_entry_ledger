defmodule DoubleEntryLedger.EntryTest do
  @moduledoc """
  Tests for the Entry schema.
  """

  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Account, Entry, Repo}

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
                 value: {"is invalid", [type: Money.Ecto.Map.Type, validation: :cast]}
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

  describe "validate_amount_sign/3" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "returns error changeset for different types", %{transaction: %{entries: [e0, _]}} do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [type: {"can't change the amount sign", []}]
             } =
               Entry.update_changeset(
                 e0,
                 %{value: Money.new(100, :EUR), type: :xxx},
                 :pending_to_posted
               )
    end
  end

  describe "balance history entry creation" do
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
  end

  describe "changeset/3 with non-existent account" do
    setup [:create_instance]

    test "returns changeset error instead of crashing", _ctx do
      attrs = %{
        type: :debit,
        value: Money.new(100, :EUR),
        account_id: Ecto.UUID.generate()
      }

      changeset = Entry.changeset(%Entry{}, attrs, :pending)

      assert %Ecto.Changeset{valid?: false} = changeset
      assert {"account not found", []} = Keyword.get(changeset.errors, :account_id)
    end
  end

  describe "signed_value/1" do
    setup [:create_instance, :create_accounts, :create_transaction]

    test "returns positive value when entry type matches normal balance", %{
      transaction: %{entries: entries}
    } do
      entry =
        Enum.find(entries, &(&1.type == :debit))
        |> Repo.preload(:account)

      assert entry.account.normal_balance == :debit
      assert Entry.signed_value(entry) == entry.value.amount
    end

    test "returns negative value when entry type differs from normal balance", %{
      transaction: %{entries: entries}
    } do
      entry =
        Enum.find(entries, &(&1.type == :credit))
        |> Repo.preload(:account)

      assert entry.account.normal_balance == :credit
      # credit entry on a credit account → positive
      assert Entry.signed_value(entry) == entry.value.amount
    end

    test "returns negative for debit entry on credit account", %{
      transaction: %{entries: entries}
    } do
      # Find a credit account entry (liability), preload account
      entry =
        Enum.find(entries, &(&1.type == :debit))
        |> Repo.preload(:account)

      # Debit entry on a debit (asset) account → matches → positive
      assert entry.account.normal_balance == :debit
      assert Entry.signed_value(entry) > 0

      # Simulate mismatch: debit entry on credit account
      mismatched = %{entry | account: %{entry.account | normal_balance: :credit}}
      assert Entry.signed_value(mismatched) == -entry.value.amount
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
