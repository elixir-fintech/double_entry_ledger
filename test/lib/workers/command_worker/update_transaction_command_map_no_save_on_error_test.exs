defmodule DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMapNoSaveOnErrorTest do
  @moduledoc """
  This module tests the UpdateTransactionCommandMapNoSaveOnError module.
  """
  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import Mox

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.TransactionCommandMap, as: TransactionCommandMapSchema
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMapNoSaveOnError
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommand

  doctest UpdateTransactionCommandMapNoSaveOnError

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "update command for command_map, which should also create the command", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, _} =
        CreateTransactionCommand.process(pending_command)

      update_command = update_transaction_command_map(ctx, pending_command, :posted)

      {:ok, transaction, %{command_queue_item: cqi} = processed_command} =
        UpdateTransactionCommandMapNoSaveOnError.process(update_command)

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
      CreateTransactionCommand.process(pending_command)
      update_command = update_transaction_command_map(ctx, pending_command, :posted)
      UpdateTransactionCommandMapNoSaveOnError.process(update_command)

      # process same update_command again which should fail
      {:error, changeset} = UpdateTransactionCommandMapNoSaveOnError.process(update_command)
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

      assert {:error,
              %Changeset{
                data: %TransactionCommandMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_command_not_found", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionCommandMapNoSaveOnError.process(update_transaction_command_map)
    end

    test "return TransactionCommandMap changeset for other errors", ctx do
      command_map = %{
        create_transaction_command_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      updated_command_map =
        update_in(
          command_map,
          [Access.key!(:payload), Access.key!(:entries), Access.at(1), Access.key!(:currency)],
          fn _ ->
            "USD"
          end
        )

      # process same update_command again which should fail
      {:error, changeset} =
        UpdateTransactionCommandMapNoSaveOnError.process(updated_command_map)

      assert %Changeset{data: %TransactionCommandMapSchema{}} = changeset
    end

    test "return TransactionCommandMap changeset for invalid entry data currency", ctx do
      command_map = %{
        create_transaction_command_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      updated_command_map =
        update_in(
          command_map,
          [Access.key!(:payload), Access.key!(:entries), Access.at(1), Access.key!(:currency)],
          fn _ ->
            "XYZ"
          end
        )

      {:error, changeset} =
        UpdateTransactionCommandMapNoSaveOnError.process(updated_command_map)

      assert %Changeset{
               data: %TransactionCommandMapSchema{},
               errors: [
                 input_command_map: {"invalid_entry_data", []},
                 action: {"invalid in this context", [value: ""]}
               ]
             } = changeset
    end

    test "return TransactionCommandMap changeset for non existing account", ctx do
      command_map = %{
        create_transaction_command_map(ctx, :pending)
        | update_idempk: Ecto.UUID.generate(),
          action: :update_transaction
      }

      updated_command_map =
        update_in(
          command_map,
          [
            Access.key!(:payload),
            Access.key!(:entries),
            Access.at(1),
            Access.key!(:account_address)
          ],
          fn _ ->
            "non:existing:#{:rand.uniform(1000)}"
          end
        )

      {:error, changeset} =
        UpdateTransactionCommandMapNoSaveOnError.process(updated_command_map)

      assert %Changeset{
               data: %TransactionCommandMapSchema{},
               errors: [
                 input_command_map: {"some_accounts_not_found", []},
                 action: {"invalid in this context", [value: ""]}
               ]
             } = changeset
    end

    test "update command for command_map, when create command not yet processed", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      update_command = update_transaction_command_map(ctx, pending_command, :posted)

      assert {:error,
              %Changeset{
                data: %TransactionCommandMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_command_not_processed", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionCommandMapNoSaveOnError.process(update_command)
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

      assert {:error,
              %Changeset{
                data: %TransactionCommandMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_command_not_processed", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionCommandMapNoSaveOnError.process(update_command)
    end

    test "update command is dead_letter for command_map, when create command failed", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      pending_command.command_queue_item
      |> Ecto.Changeset.change(%{status: :dead_letter})
      |> Repo.update!()

      failed_command = Repo.preload(pending_command, :command_queue_item)

      update_command = update_transaction_command_map(ctx, failed_command, :posted)

      assert {:error,
              %Changeset{
                data: %TransactionCommandMapSchema{},
                errors: [
                  create_transaction_event_error: {"create_command_in_dead_letter", _},
                  action: {"invalid in this context", [value: ""]}
                ]
              }} =
               UpdateTransactionCommandMapNoSaveOnError.process(update_command)
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

      assert {:error,
              %Changeset{
                data: %TransactionCommandMapSchema{},
                errors: [occ_timeout: _, action: _]
              }} =
               UpdateTransactionCommandMapNoSaveOnError.process(
                 update_command,
                 DoubleEntryLedger.MockRepo
               )
    end
  end
end
