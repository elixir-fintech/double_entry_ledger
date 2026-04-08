defmodule DoubleEntryLedger.Stores.CommandStoreTest do
  @moduledoc """
  This module tests the CommandStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures
  alias DoubleEntryLedger.{Command, Repo, PendingTransactionLookup}

  alias DoubleEntryLedger.Stores.{
    CommandStore,
    CommandStoreHelper,
    AccountStore,
    InstanceStore,
    TransactionStore
  }

  alias DoubleEntryLedger.Command.TransactionCommandMap

  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommand

  doctest CommandStoreHelper
  doctest CommandStore

  describe "create/1" do
    setup [:create_instance, :create_accounts]

    test "inserts a new command and adds a command_queue_item", %{instance: instance} do
      assert {:ok, %Command{id: id} = command} =
               CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert %{id: cqi_id, command_id: ^id, status: :pending} = command.command_queue_item
      assert cqi_id != nil
    end

    test "creates a lookup for pending create_transactions", %{instance: instance} do
      assert {:ok, %Command{id: id, command_map: %{source: s, source_idempk: sidpk}}} =
               CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert %{command_id: ^id, source: ^s, source_idempk: ^sidpk} =
               Repo.get_by(PendingTransactionLookup, command_id: id)
    end

    test "no lookup for posted create_transactions", ctx do
      assert {:ok, %Command{id: id, command_map: %{source: _s, source_idempk: _sidpk}}} =
               CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert is_nil(Repo.get_by(PendingTransactionLookup, command_id: id))
    end

    test "fails for invalid instance_address" do
      trx_map = transaction_command_attrs(instance_address: "1234", action: :create_transaction)

      assert {:error, %Ecto.Changeset{errors: errors}} = CommandStore.create(trx_map)
      assert Keyword.has_key?(errors, :instance_id)
    end

    test "fails when adding identical command with action: create_transaction", %{
      instance: %{address: address}
    } do
      trx_map = transaction_command_attrs(instance_address: address, action: :create_transaction)
      assert {:ok, %Command{} = _command} = CommandStore.create(trx_map)
      assert {:error, :pending_transaction_idempotency_violation} = CommandStore.create(trx_map)
    end
  end

  describe "get_command_by/4" do
    setup [:create_instance, :create_accounts]

    test "gets a command by source", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert %Command{} =
               found_command =
               CommandStoreHelper.get_command_by(
                 :create_transaction,
                 command.command_map.source,
                 command.command_map.source_idempk,
                 instance.id
               )

      assert found_command.id == command.id
    end

    test "returns processed_transaction", %{instance: instance} = ctx do
      %{command: %{command_map: command_map} = command} =
        new_create_transaction_command(ctx, :pending)

      {:ok, transaction, _} = CreateTransactionCommand.process(command)

      assert %Command{} =
               found_command =
               CommandStoreHelper.get_command_by(
                 :create_transaction,
                 command_map.source,
                 command_map.source_idempk,
                 instance.id
               )

      assert found_command.transaction.id == transaction.id
    end

    test "returns nil for non-existent command", %{instance: instance} do
      assert nil ==
               CommandStoreHelper.get_command_by(
                 :create_transaction,
                 "source",
                 "source_idempk",
                 instance.id
               )
    end
  end
end
