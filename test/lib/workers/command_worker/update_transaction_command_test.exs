defmodule DoubleEntryLedger.UpdateTransactionCommandTest do
  @moduledoc """
  This module tests the UpdateTransactionCommand module.
  """
  use ExUnit.Case
  import Mox

  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.{Command, PendingTransactionLookup, Repo}
  alias DoubleEntryLedger.Command.TransactionData

  alias DoubleEntryLedger.Workers.CommandWorker.{
    UpdateTransactionCommand,
    CreateTransactionCommand
  }

  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Stores.CommandStore

  doctest UpdateTransactionCommand

  describe "process/1" do
    setup [:create_instance, :create_accounts]

    test "process update command successfully for simple update to posted",
         %{instance: inst} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]
      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :posted)

      {:ok, transaction, processed_command} = UpdateTransactionCommand.process(command)
      shared_command_asserts(transaction, processed_command, pending_transaction)
      assert return_available_balances(ctx) == [100, 100]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "process update command successfully for simple update to :archived",
         %{instance: inst} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]
      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :archived)

      {:ok, transaction, processed_command} = UpdateTransactionCommand.process(command)
      shared_command_asserts(transaction, processed_command, pending_transaction)
      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test "process update command successfully for changing entries and to :posted",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, command} =
        new_update_transaction_command(s, s_id, inst.address, :posted, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_command} = UpdateTransactionCommand.process(command)
      shared_command_asserts(transaction, processed_command, pending_transaction)
      assert return_available_balances(ctx) == [50, 50]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "process update command successfully for changing entries and to :pending",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, command} =
        new_update_transaction_command(s, s_id, inst.address, :pending, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_command} = UpdateTransactionCommand.process(command)
      shared_command_asserts(transaction, processed_command, pending_transaction)
      assert return_pending_balances(ctx) == [50, 50]
      assert transaction.status == :pending
    end

    test "process update command successfully to :archived",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, command} =
        new_update_transaction_command(s, s_id, inst.address, :archived, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, processed_command} = UpdateTransactionCommand.process(command)
      shared_command_asserts(transaction, processed_command, pending_transaction)
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :archived
    end

    test ":pending_to_posted DELETEs the pending_transaction_lookup row",
         %{instance: inst} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      {:ok, _tx, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      assert Repo.get_by!(PendingTransactionLookup,
               instance_id: inst.id,
               source: s,
               source_idempk: s_id
             )

      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :posted)
      {:ok, _tx, _cmd} = UpdateTransactionCommand.process(command)

      refute Repo.get_by(PendingTransactionLookup,
               instance_id: inst.id,
               source: s,
               source_idempk: s_id
             )
    end

    test ":pending_to_archived DELETEs the pending_transaction_lookup row",
         %{instance: inst} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      {:ok, _tx, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :archived)
      {:ok, _tx, _cmd} = UpdateTransactionCommand.process(command)

      refute Repo.get_by(PendingTransactionLookup,
               instance_id: inst.id,
               source: s,
               source_idempk: s_id
             )
    end

    test ":pending_to_pending leaves the pending_transaction_lookup row intact",
         %{instance: inst, accounts: [a1, a2, _, _]} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)
      {:ok, _tx, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      {:ok, command} =
        new_update_transaction_command(s, s_id, inst.address, :pending, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, _tx, _cmd} = UpdateTransactionCommand.process(command)

      # Row still exists — tx is still :pending so the lookup is still
      # needed (a future update may still come).
      assert Repo.get_by!(PendingTransactionLookup,
               instance_id: inst.id,
               source: s,
               source_idempk: s_id
             )
    end

    test "dead letter when create command does not exist", %{instance: inst} do
      {:ok, command} = new_update_transaction_command("source", "1", inst.address, :posted)

      {:error, %{command_queue_item: cqi}} = UpdateTransactionCommand.process(command)
      assert cqi.status == :dead_letter

      [error | _] = cqi.errors

      assert error.message ==
               "create Command not found for Update Command (id: #{command.id})"
    end

    test "back to pending when create command is still pending", %{instance: inst} = ctx do
      %{command: %{id: e_id, command_map: %{source: s, source_idempk: s_id}}} =
        new_create_transaction_command(ctx, :pending)

      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :posted)

      {:ok, processing_command} = Scheduling.claim_command_for_processing(command.id, "manual")

      {:error, %{command_queue_item: eqm}} = UpdateTransactionCommand.process(processing_command)
      assert eqm.status == :pending

      [error | _] = eqm.errors

      assert error.message ==
               "create Command (id: #{e_id}, status: pending) not yet processed for Update Command (id: #{command.id})"
    end

    test "back to pending when create command failed", %{instance: inst} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      {:error, failed_create_command} =
        DoubleEntryLedger.CommandQueue.Scheduling.schedule_retry_with_reason(
          pending_command,
          "some reason",
          :failed
        )

      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :posted)

      {:error, %{command_queue_item: eqm}} = UpdateTransactionCommand.process(command)
      assert eqm.status == :pending

      [error | _] = eqm.errors

      assert failed_create_command.command_queue_item.status == :failed

      assert error.message ==
               "create Command (id: #{pending_command.id}, status: failed) not yet processed for Update Command (id: #{command.id})"
    end

    test "dead_letter when create command in dead_letter", %{instance: inst} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      DoubleEntryLedger.CommandQueue.Scheduling.build_mark_as_dead_letter(
        pending_command,
        "some reason"
      )
      |> DoubleEntryLedger.Repo.update!()

      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :posted)

      {:error, %{command_queue_item: eqm}} = UpdateTransactionCommand.process(command)
      assert eqm.status == :dead_letter

      [error | _] = eqm.errors

      assert error.message ==
               "create Command (id: #{pending_command.id}) in dead_letter for Update Command (id: #{command.id})"
    end

    test "dead_letter when transaction_map_error", %{instance: inst, accounts: [a | _]} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}}} =
        new_create_transaction_command(ctx, :pending)

      {:ok, command} =
        CommandStore.create(
          transaction_command_attrs(
            action: :update_transaction,
            source: s,
            source_idempk: s_id,
            update_idempk: "1",
            instance_address: inst.address,
            payload: %TransactionData{
              status: :posted,
              entries: [
                %{account_address: a.address, amount: 100, currency: "EUR"},
                %{account_address: "nonexisting:account", amount: 100, currency: "EUR"}
              ]
            }
          )
        )

      {:error, %{command_queue_item: eqm}} = UpdateTransactionCommand.process(command)
      assert eqm.status == :dead_letter

      [error | _] = eqm.errors

      assert error.message == ":some_accounts_not_found"
    end

    test "update command with last retry that fails", %{instance: inst} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, _pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      {:ok, command} = new_update_transaction_command(s, s_id, inst.address, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, 5, fn _changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
      end)
      |> expect(:update!, 7, fn changeset ->
        # simulate a conflict when adding the transaction
        Repo.update!(changeset)
      end)
      |> expect(:transaction, 6, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      {:error, %{command_queue_item: eqm} = updated_command} =
        UpdateTransactionCommand.process(command, DoubleEntryLedger.MockRepo)

      assert eqm.status == :occ_timeout
      assert eqm.occ_retry_count == 5
      %{transaction: nil} = Repo.preload(updated_command, :transaction)
      assert eqm.processing_completed_at != nil
      assert length(eqm.errors) == 5
      assert eqm.retry_count == 0
      assert eqm.next_retry_after != nil

      assert [%{message: "OCC conflict: Max number of 5 retries reached"} | _] =
               eqm.errors
    end

    test "when transaction can't be created for other reasons", %{instance: inst} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, _pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CreateTransactionCommand.process(pending_command)

      {:ok, command} =
        new_update_transaction_command(s, s_id, inst.address, :posted)

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn changeset ->
        # simulate a conflict when adding the transaction
        {:error, Ecto.Changeset.add_error(changeset, :entries, ":conflict")}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, %Command{command_queue_item: eqm}} =
               UpdateTransactionCommand.process(
                 command,
                 DoubleEntryLedger.MockRepo
               )

      assert eqm.status == :dead_letter

      assert [
               %{
                 message:
                   "TransactionCommandResponseHandler: Transaction changeset failed %{entries: [\":conflict\"]}"
               }
               | _
             ] =
               eqm.errors
    end
  end

  defp shared_command_asserts(transaction, processed_command, pending_transaction) do
    assert processed_command.command_queue_item.status == :processed

    %{transaction: processed_transaction} =
      processed_command = Repo.preload(processed_command, :transaction)

    assert processed_transaction.id == pending_transaction.id
    assert transaction.id == pending_transaction.id
    assert processed_command.command_queue_item.processing_completed_at != nil
  end
end
