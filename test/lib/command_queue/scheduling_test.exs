defmodule DoubleEntryLedger.CommandQueue.SchedulingTest do
  @moduledoc """
  Tests for the scheduling of commands in the command queue.
  """
  use ExUnit.Case, async: true
  import Mox
  import ExUnit.CaptureLog
  alias Ecto.Changeset
  use DoubleEntryLedger.RepoCase
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError

  describe "claim_command_for_processing/2" do
    setup [:create_instance, :create_accounts]

    test "returns error when command not found" do
      assert {:error, :command_not_found} =
               Scheduling.claim_command_for_processing(Ecto.UUID.generate(), "manual")
    end

    test "returns error when command not claimable", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command =
        command
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_assoc(:command_queue_item, %{
          id: command.command_queue_item.id,
          status: :processed
        })
        |> Repo.update!()

      assert {:error, :command_not_claimable} =
               Scheduling.claim_command_for_processing(command.id, "manual")
    end

    test "claims a command for processing", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert {:ok, %Command{command_queue_item: eqm} = claimed_command} =
               Scheduling.claim_command_for_processing(command.id, "manual")

      assert eqm.status == :processing
      assert eqm.command_id == claimed_command.id
      assert eqm.processor_id == "manual"
      assert eqm.processing_started_at != nil
      assert eqm.processing_completed_at == nil
      assert eqm.retry_count == 0
      assert eqm.next_retry_after == nil
    end

    test "returns an error when stale entry error occurs", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      DoubleEntryLedger.MockRepo
      |> expect(:update, fn _changeset ->
        raise Ecto.StaleEntryError, action: :update_transaction, changeset: %Ecto.Changeset{}
      end)

      assert {:error, :command_already_claimed} =
               Scheduling.claim_command_for_processing(
                 command.id,
                 "manual",
                 DoubleEntryLedger.MockRepo
               )
    end
  end

  describe "claim_batch_for_processing/3" do
    setup [:create_instance, :create_accounts]

    test "claims each command exactly like the single-command path", %{instance: instance} do
      # Two identically-seeded commands (a prior :occ_timeout attempt with
      # retry_count 2). Claiming one via the single-command path and the
      # other via the batch path must produce the same queue-item changes —
      # this pins batch-claim ≡ single-claim so the two paths can't drift.
      single = seed_occ_timeout_command(instance, 2)
      batched = seed_occ_timeout_command(instance, 2)

      {:ok, %Command{command_queue_item: single_qi}} =
        Scheduling.claim_command_for_processing(single.id, "proc-1")

      [%Command{command_queue_item: batch_qi}] =
        Scheduling.claim_batch_for_processing([batched], "proc-1")

      assert single_qi.status == :processing
      assert batch_qi.status == :processing

      # Re-claim of a non-:pending command bumps retry_count 2 → 3 in both.
      assert single_qi.retry_count == 3
      assert batch_qi.retry_count == 3

      assert single_qi.processor_id == "proc-1"
      assert batch_qi.processor_id == "proc-1"

      assert single_qi.next_retry_after == nil
      assert batch_qi.next_retry_after == nil

      assert single_qi.processing_started_at != nil
      assert batch_qi.processing_started_at != nil

      assert single_qi.processing_completed_at == nil
      assert batch_qi.processing_completed_at == nil

      # processor_version advanced identically from the seeded baseline.
      assert single_qi.processor_version == batch_qi.processor_version
    end

    test "leaves retry_count unchanged when claiming a :pending command", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command = CommandStore.get_by_id(command.id)

      [%Command{command_queue_item: qi}] =
        Scheduling.claim_batch_for_processing([command], "proc-1")

      assert qi.status == :processing
      assert qi.retry_count == 0
    end

    test "skips commands that are not in a claimable state", %{instance: instance} do
      claimable = seed_occ_timeout_command(instance, 0)
      not_claimable = seed_occ_timeout_command(instance, 0)

      not_claimable.command_queue_item
      |> Changeset.change(%{status: :processed})
      |> Repo.update!()

      claimed = Scheduling.claim_batch_for_processing([claimable, not_claimable], "proc-1")

      assert Enum.map(claimed, & &1.id) == [claimable.id]
    end
  end

  defp seed_occ_timeout_command(instance, retry_count) do
    {:ok, command} =
      CommandStore.create(
        transaction_command_attrs(
          instance_address: instance.address,
          source_idempk: "idempk-#{System.unique_integer([:positive])}"
        )
      )

    command.command_queue_item
    |> Changeset.change(%{status: :occ_timeout, retry_count: retry_count})
    |> Repo.update!()

    CommandStore.get_by_id(command.id)
  end

  describe "build_mark_as_processed/1" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to mark command as processed", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_mark_as_processed(command)

      assert command_queue_item.valid?
      assert command_queue_item.changes.status == :processed
      assert command_queue_item.changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(command_queue_item, :next_retry_after) == nil
    end
  end

  describe "build_mark_as_dead_letter/2" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to mark command as dead letter", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      error = "Test error"

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_mark_as_dead_letter(command, error)

      assert command_queue_item.valid?
      assert command_queue_item.changes.status == :dead_letter
      assert command_queue_item.changes.processing_completed_at != nil
      assert Ecto.Changeset.get_field(command_queue_item, :next_retry_after) == nil
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == error end)
    end

    test "logs at error level when dead-lettering", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      log =
        capture_log([level: :error], fn ->
          Scheduling.build_mark_as_dead_letter(command, "Terminal failure")
        end)

      assert log =~ "dead-lettering command #{command.id}"
      assert log =~ "Terminal failure"
    end
  end

  describe "build_revert_to_pending/2" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to revert command to pending", %{instance: instance} do
      {:ok, pending_command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, command} = Scheduling.claim_command_for_processing(pending_command.id, "manual")
      error = "Test error"

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_revert_to_pending(command, error)

      assert command_queue_item.valid?
      assert command_queue_item.changes.status == :pending
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == error end)
    end
  end

  describe "build_schedule_retry_with_reason" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to schedule retry with reason", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      error = "Test error"
      reason = :failed

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_schedule_retry_with_reason(command, error, reason)

      assert command_queue_item.valid?
      assert command_queue_item.changes.status == reason
      assert command_queue_item.changes.next_retry_after != nil
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == error end)
    end
  end

  describe "build_schedule_update_retry" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to schedule update_retry", %{instance: instance} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      {:error, failed_create_command} =
        DoubleEntryLedger.CommandQueue.Scheduling.schedule_retry_with_reason(
          pending_command,
          "some reason",
          :failed
        )

      {:ok, command} = new_update_transaction_command(s, s_id, instance.address, :posted)
      test_message = "Test error"

      error = %UpdateCommandError{
        create_command: failed_create_command,
        update_command: command,
        message: test_message,
        reason: :create_command_not_processed
      }

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_schedule_update_retry(command, error)

      assert command_queue_item.valid?
      assert command_queue_item.changes.status == :failed
      assert command_queue_item.changes.next_retry_after != nil
      assert Changeset.get_field(command_queue_item, :retry_count) == 0
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == test_message end)
    end
  end
end
