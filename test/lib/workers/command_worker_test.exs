defmodule DoubleEntryLedger.Workers.CommandWorkerTest do
  @moduledoc """
  This module tests the CommandWorker.
  """
  use ExUnit.Case
  alias DoubleEntryLedger.Command.TransactionCommandMap
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  alias DoubleEntryLedger.Stores.CommandStore

  alias DoubleEntryLedger.Workers.CommandWorker

  doctest CommandWorker

  describe "process_command_with_id/1" do
    setup [:create_instance, :create_accounts]

    test "returns ownership lost when another processor replaces its claim", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx)
      handler_id = "steal-command-claim-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:double_entry_ledger, :command, :claim],
        &__MODULE__.replace_claim_owner/4,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :command_ownership_lost} =
               CommandWorker.process_command_with_id(pending_command.id, "old-owner")

      current = CommandStore.get_by_id(pending_command.id).command_queue_item
      assert current.status == :processing
      assert current.processor_id == "replacement-owner"
    end

    test "process create command successfully", ctx do
      %{command: pending_command} = new_create_transaction_command(ctx)

      {:ok, transaction, %{command_queue_item: cqi} = processed_command} =
        CommandWorker.process_command_with_id(pending_command.id)

      assert cqi.status == :processed

      %{transaction: processed_transaction} = CommandStore.get_by_id(processed_command.id)

      assert return_available_balances(ctx) == [100, 100]
      assert processed_transaction.id == transaction.id
      assert cqi.processing_completed_at != nil
      assert transaction.status == :posted
    end

    test "update command for changing entries and to :posted",
         %{instance: inst, accounts: [a1, a2 | _]} = ctx do
      %{command: pending_command} = new_create_transaction_command(ctx, :pending)

      {:ok, pending_transaction, %{command_map: %{source: s, source_idempk: s_id}}} =
        CommandWorker.process_command_with_id(pending_command.id)

      assert return_available_balances(ctx) == [0, 0]
      assert return_pending_balances(ctx) == [100, 100]

      {:ok, command} =
        new_update_transaction_command(s, s_id, inst.address, :posted, [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ])

      {:ok, transaction, %{command_queue_item: cqi} = processed_command} =
        CommandWorker.process_command_with_id(command.id)

      assert cqi.status == :processed

      %{transaction: processed_transaction} = CommandStore.get_by_id(processed_command.id)

      assert processed_transaction.id == pending_transaction.id
      assert transaction.id == pending_transaction.id
      assert cqi.processing_completed_at != nil
      assert return_available_balances(ctx) == [50, 50]
      assert return_pending_balances(ctx) == [0, 0]
      assert transaction.status == :posted
    end

    test "don't process commands with status [:processed, :dead_letter]", ctx do
      %{command: command} = new_create_transaction_command(ctx)
      CommandWorker.process_command_with_id(command.id)

      assert {:error, :command_not_claimable} =
               CommandWorker.process_command_with_id(command.id)

      command
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(
        :command_queue_item,
        %{id: command.command_queue_item.id, status: :dead_letter}
      )
      |> Repo.update!()

      assert {:error, :command_not_claimable} =
               CommandWorker.process_command_with_id(command.id)
    end

    test "does not process a command whose retry deadline is still in the future", ctx do
      %{command: command} = new_create_transaction_command(ctx)
      reschedule_retry_relative_to_db_clock(command.id, 1)

      assert {:error, :command_not_claimable} =
               CommandWorker.process_command_with_id(command.id)

      current = CommandStore.get_by_id(command.id).command_queue_item
      assert current.status == :occ_timeout
      assert current.processor_id == nil
      assert current.processing_started_at == nil
    end
  end

  def replace_claim_owner(_event, _measurements, %{command_id: command_id}, _config) do
    command_id
    |> CommandStore.get_by_id()
    |> Map.fetch!(:command_queue_item)
    |> Ecto.Changeset.change(processor_id: "replacement-owner")
    |> Ecto.Changeset.optimistic_lock(:processor_version)
    |> Repo.update!()
  end

  describe "process_command_map/1" do
    setup [:create_instance, :create_accounts]

    test "create command for command_map, which must also create the command", %{
      instance: inst,
      accounts: [a1, a2, _, _]
    } do
      {:ok, command_map} =
        %{
          action: :create_transaction,
          instance_address: inst.address,
          source: "source",
          source_data: %{},
          source_idempk: "source_idempk",
          update_idempk: nil,
          payload: %{
            status: :pending,
            entries: [
              %{account_address: a1.address, amount: 100, currency: "EUR"},
              %{account_address: a2.address, amount: 100, currency: "EUR"}
            ]
          }
        }
        |> TransactionCommandMap.create()

      {:ok, transaction, %{command_queue_item: cqi} = processed_command} =
        CommandWorker.process_new_command(command_map)

      assert cqi.status == :processed

      %{transaction: processed_transaction} = Repo.preload(processed_command, :transaction)

      assert processed_transaction.id == transaction.id
      assert cqi.processing_completed_at != nil
      assert transaction.status == :pending
    end
  end
end
