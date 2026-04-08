defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMapTest do
  @moduledoc """
  This module tests the TransactionCommandMap module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import Mox

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.TransactionCommandMap, as: TransactionCommandMapSchema
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMap
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommand
  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Stores.CommandStore

  doctest UpdateTransactionCommandMap

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "update command for command_map, which should also create the command", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateTransactionCommand.process(pending_command)

      update_command = update_transaction_command_map(ctx, pending_command, :posted)

      {:ok, transaction, %{command_queue_item: cqi} = processed_command} =
        UpdateTransactionCommandMap.process(update_command)

      assert cqi.status == :processed

      %{transaction: processed_transaction} = Repo.preload(processed_command, :transaction)

      assert processed_transaction.id == transaction.id
      assert processed_transaction.id == pending_transaction.id
      assert cqi.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "return TransactionCommandMap changeset for duplicate update_idempk", ctx do
      # successfully create command
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      update_command = update_transaction_command_map(ctx, pending_command, :posted)
      UpdateTransactionCommandMap.process(update_command)

      # process same update_command again which should fail
      {:error, changeset} = UpdateTransactionCommandMap.process(update_command)
      assert %Changeset{data: %TransactionCommandMapSchema{}} = changeset
      assert Keyword.has_key?(changeset.errors, :key_hash)
    end

    test "dead letter when create command does not exist", ctx do
      command_map = create_transaction_command_map(ctx, :pending)

      update_transaction_command_map = %{
        command_map
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      {:error, %{command_queue_item: %{status: status, errors: [error | _]}}} =
        UpdateTransactionCommandMap.process(update_transaction_command_map)

      assert status == :dead_letter
      assert error.message =~ "create Command not found for Update Command (id:"
    end

    test "update command for command_map, when create command not yet processed", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      update_command = update_transaction_command_map(ctx, pending_command, :posted)

      {:error, %{command_queue_item: eqm} = update_command} =
        UpdateTransactionCommandMap.process(update_command)

      assert eqm.status == :pending
      assert update_command.id != pending_command.id
      %{transaction: nil} = Repo.preload(update_command, :transaction)
      assert eqm.processing_completed_at == nil
      assert eqm.errors != []
    end

    test "update command is pending for command_map, when create command failed", ctx do
      %{command: %{command_queue_item: eqm1} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      failed_command =
        pending_command
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.put_assoc(:command_queue_item, %{id: eqm1.id, status: :failed})
        |> Repo.update!()

      update_command = update_transaction_command_map(ctx, failed_command, :posted)

      {:error, %{command_queue_item: eqm}} = UpdateTransactionCommandMap.process(update_command)

      assert eqm.status == :pending
    end

    test "update command is dead_letter for command_map, when create command failed", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      pending_command.command_queue_item
      |> Ecto.Changeset.change(%{status: :dead_letter})
      |> Repo.update!()

      failed_command = Repo.preload(pending_command, :command_queue_item)

      update_command = update_transaction_command_map(ctx, failed_command, :posted)

      {:error, %{command_queue_item: cqi}} = UpdateTransactionCommandMap.process(update_command)

      assert cqi.status == :dead_letter
    end
  end

  TODO

  describe "process/2 with OCC timeout" do
    # , :verify_on_exit!]
    setup [:create_instance, :create_accounts]

    test "with last retry that fails", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      CreateTransactionCommand.process(pending_command)
      update_command = update_transaction_command_map(ctx, pending_command, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, 5, fn changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: changeset
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Command{id: id, command_queue_item: %{status: :occ_timeout}}} =
               UpdateTransactionCommandMap.process(update_command, DoubleEntryLedger.MockRepo)

      assert %Command{
               command_queue_item: %{status: :occ_timeout, occ_retry_count: 5, errors: errors},
               transaction: nil
             } =
               CommandStore.get_by_id(id) |> Repo.preload(:transaction)

      assert length(errors) == 5
      assert [%{"message" => "OCC conflict: Max number of 5 retries reached"} | _] = errors
    end
  end
end
