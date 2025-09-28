defmodule DoubleEntryLedger.Stores.TransactionStoreTest do
  @moduledoc """
  This module tests the TransactionStore and TransactionStoreHelper module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import Mox

  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures, TransactionFixtures}
  alias DoubleEntryLedger.{TransactionStore, Repo}
  alias DoubleEntryLedger.Stores.{TransactionStore, TransactionStoreHelper}
  alias Ecto.Multi

  doctest TransactionStore
  doctest TransactionStoreHelper

  describe "build_create/4" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "can handle StaleEntryError so the multi step returns a Multi.failure()", %{
      instance: inst,
      accounts: [a1, a2, _, _]
    } do
      attr =
        transaction_attr(
          status: :pending,
          instance_id: inst.id,
          entries: [
            %{type: :debit, value: Money.new(100, :EUR), account_id: a1.id},
            %{type: :credit, value: Money.new(100, :EUR), account_id: a2.id}
          ]
        )

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn _changeset ->
        raise Ecto.StaleEntryError, action: :insert, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Ecto.Multi.new()
               |> TransactionStoreHelper.build_create(
                 :transaction,
                 attr,
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end
  end

  describe "build_update/5" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "with transaction, can handle StaleEntryError so the multi step returns a Multi.failure()",
         ctx do
      %{transaction: trx} = create_transaction(ctx, :pending)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Multi.new()
               |> TransactionStoreHelper.build_update(
                 :transaction,
                 trx,
                 %{status: :posted},
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end

    test "with transaction_step, can handle StaleEntryError so the multi step returns a Multi.failure()",
         ctx do
      %{transaction: trx} = create_transaction(ctx, :pending)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :transaction, %Ecto.StaleEntryError{message: _}, %{}} =
               Multi.new()
               |> Multi.run(:create_event_trx, fn _repo, _changes -> {:ok, trx} end)
               |> TransactionStoreHelper.build_update(
                 :transaction,
                 :create_event_trx,
                 %{status: :posted},
                 DoubleEntryLedger.MockRepo
               )
               |> Repo.transaction()
    end
  end
end
