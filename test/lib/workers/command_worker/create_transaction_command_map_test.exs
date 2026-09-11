defmodule DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMapTest do
  @moduledoc """
  This module tests the CreateTransactionCommandMap module, which processes command maps for atomic creation and update of commands and their associated transactions. It ensures correct OCC handling, error mapping, and transactional guarantees.
  """
  use ExUnit.Case
  import Mox

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.{TransactionCommandMap, TransactionData, EntryData}
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMap
  alias DoubleEntryLedger.{Command, PendingTransactionLookup}
  alias DoubleEntryLedger.Stores.CommandStore

  doctest CreateTransactionCommandMap

  describe "process_map/1" do
    setup [:create_instance, :create_accounts]

    test "create command for command_map, which must also create the command", ctx do
      command_map = create_transaction_command_map(ctx)

      {:ok, transaction, %{command_queue_item: cqi} = processed_command} =
        CreateTransactionCommandMap.process(command_map)

      assert cqi.status == :processed

      %{transaction: processed_transaction} = Repo.preload(processed_command, :transaction)

      assert processed_transaction.id == transaction.id
      assert cqi.processing_completed_at != nil
      assert transaction.status == :pending
    end

    test "pending transaction also creates a pending transaction lookup", ctx do
      command_map = create_transaction_command_map(ctx, :pending)

      {:ok, %{id: trx_id}, %{id: id}} = CreateTransactionCommandMap.process(command_map)

      assert %{command_id: ^id, transaction_id: ^trx_id} =
               Repo.get_by(PendingTransactionLookup, command_id: id)
    end

    test "posted transaction don't create a pending transaction lookup", ctx do
      command_map = create_transaction_command_map(ctx, :posted)

      {:ok, _, %{id: id}} = CreateTransactionCommandMap.process(command_map)
      assert is_nil(Repo.get_by(PendingTransactionLookup, command_id: id))
    end

    test "return TransactionCommandMap changeset for duplicate source_idempk", ctx do
      # successfully create command
      command_map = create_transaction_command_map(ctx)
      CreateTransactionCommandMap.process(command_map)

      # process same command_map again which should fail
      {:error, changeset} = CreateTransactionCommandMap.process(command_map)
      assert %Changeset{data: %TransactionCommandMap{}} = changeset
      assert Keyword.has_key?(changeset.errors, :key_hash)
    end

    test "return TransactionCommandMap changeset for other errors", ctx do
      # successfully create command
      command_map = create_transaction_command_map(ctx, :pending)

      updated_command_map =
        update_in(
          command_map,
          [Access.key!(:payload), Access.key!(:entries), Access.at(1), Access.key!(:currency)],
          fn _ ->
            "USD"
          end
        )

      {:error, changeset} =
        CreateTransactionCommandMap.process(updated_command_map)

      assert %Changeset{data: %TransactionCommandMap{}} = changeset
    end

    test "return TransactionCommandMap for transaction_map error", %{
      instance: inst,
      accounts: [a | _]
    } do
      command_map =
        transaction_command_attrs(
          instance_address: inst.address,
          payload: %TransactionData{
            status: :posted,
            entries: [
              %EntryData{account_address: a.address, amount: 100, currency: "EUR"},
              %EntryData{account_address: "nonexisting:account", amount: 100, currency: "EUR"}
            ]
          }
        )

      {:error, changeset} =
        CreateTransactionCommandMap.process(command_map)

      assert %Changeset{data: %TransactionCommandMap{}} = changeset
    end
  end

  describe "process/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      telemetry_ref = attach_telemetry([:double_entry_ledger, :command, :retry])

      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Command{id: id, command_queue_item: %{status: :occ_timeout}}} =
               CreateTransactionCommandMap.process(
                 create_transaction_command_map(ctx, :pending),
                 DoubleEntryLedger.MockRepo
               )

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5, errors: errors},
               transaction: nil
             } =
               CommandStore.get_by_id(id) |> Repo.preload(:transaction)

      assert length(errors) == 5
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = errors

      assert_receive {:telemetry_event, ^telemetry_ref, [:double_entry_ledger, :command, :retry],
                      _measurements, %{command_id: ^id, status: :occ_timeout}}
    end

    test "creates a pending_transaction_lookup for commands with pending status", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi -> Repo.transaction(multi) end)

      {:error, %Command{id: id}} =
        CreateTransactionCommandMap.process(
          create_transaction_command_map(ctx, :pending),
          DoubleEntryLedger.MockRepo
        )

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5}
             } =
               CommandStore.get_by_id(id)

      assert %{command_id: ^id} = Repo.get_by(PendingTransactionLookup, command_id: id)
    end

    test "does not create a pending_transaction_lookup for other commands", ctx do
      DoubleEntryLedger.MockRepo
      |> expect(:insert, 5, fn changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi -> Repo.transaction(multi) end)

      {:error, %Command{id: id}} =
        CreateTransactionCommandMap.process(
          create_transaction_command_map(ctx, :posted),
          DoubleEntryLedger.MockRepo
        )

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5}
             } =
               CommandStore.get_by_id(id)

      assert is_nil(Repo.get_by(PendingTransactionLookup, command_id: id))
    end
  end
end
