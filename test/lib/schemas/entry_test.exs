defmodule DoubleEntryLedger.EntryTest do
  @moduledoc """
  Tests for the Entry schema.
  """

  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Entry, Repo}

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures

  describe "entries" do
    setup [:create_instance, :create_account]

    test "returns error changeset for missing fields", _ctx do
      assert %Ecto.Changeset{
        valid?: false,
        errors: [
          type: {"can't be blank", [validation: :required]},
          amount: {"can't be blank", [validation: :required]},
          account_id: {"can't be blank", [validation: :required]}
        ]
      } = Entry.changeset(%Entry{}, %{})
    end

    # validation allows empty transaction_id, but must be present in db
    # Entries must have a transaction_id, and transaction must have at least 2 entries
    test "raises not-null constraint error for missing transaction_id", ctx do
      attr = entry_attr(account_id: ctx.account.id)
      assert_raise Postgrex.Error,
        ~r/"transaction_id" of relation "entries" violates not-null constraint/,
        fn -> Repo.insert(Entry.changeset(%Entry{}, attr)) end
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
        amount: Money.new(100, :EUR),
        type: :debit
      })
  end
end
