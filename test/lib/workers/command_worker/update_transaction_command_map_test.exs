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
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMap
  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Stores.CommandStore

  doctest UpdateTransactionCommandMap

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "returns a changeset when the transaction map cannot be built", ctx do
      command_map = command_map_with_unknown_accounts(ctx, :update_transaction)

      assert {:error, %Changeset{} = changeset} =
               UpdateTransactionCommandMap.process(command_map)

      assert {_msg, _} = changeset.errors[:input_command_map]
    end

    test "fails the same way the create path does for an unbuildable transaction map", ctx do
      assert {:error, %Changeset{}} =
               CreateTransactionCommandMap.process(
                 command_map_with_unknown_accounts(ctx, :create_transaction)
               )

      assert {:error, %Changeset{}} =
               UpdateTransactionCommandMap.process(
                 command_map_with_unknown_accounts(ctx, :update_transaction)
               )
    end

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
      telemetry_ref = attach_telemetry([:double_entry_ledger, :command, :dead_letter])
      command_map = create_transaction_command_map(ctx, :pending)

      update_transaction_command_map = %{
        command_map
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      {:error, %{id: command_id, command_queue_item: %{status: status, errors: [error | _]}}} =
        UpdateTransactionCommandMap.process(update_transaction_command_map)

      assert status == :dead_letter
      assert error.message =~ "create Command not found for Update Command (id:"

      assert_receive {:telemetry_event, ^telemetry_ref,
                      [:double_entry_ledger, :command, :dead_letter], _measurements,
                      %{command_id: ^command_id}}
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

  # Entries naming accounts that do not exist, so
  # `TransactionCommandTransformer.transaction_data_to_transaction_map/2` returns
  # `{:error, :no_accounts_found}` and the module's transaction-map error handler runs.
  defp command_map_with_unknown_accounts(%{instance: %{address: address}}, action) do
    %TransactionCommandMapSchema{
      action: action,
      instance_address: address,
      source: "unknown-accounts",
      source_idempk: Ecto.UUID.generate(),
      update_idempk: Ecto.UUID.generate(),
      payload: %DoubleEntryLedger.Command.TransactionData{
        status: :posted,
        entries: [
          %{account_address: "does:not:exist:1", amount: 50, currency: "EUR"},
          %{account_address: "does:not:exist:2", amount: 50, currency: "EUR"}
        ]
      }
    }
  end
end
