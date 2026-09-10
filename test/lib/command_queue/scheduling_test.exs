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
  alias DoubleEntryLedger.{Command, CommandQueueItem}
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError

  # `Scheduling.calculate_retry_delay/1` for retry_count 0: base delay plus a
  # jitter of 1..(base/10 + 1) seconds.
  @base_retry_delay Application.compile_env(:double_entry_ledger, :command_queue, [])
                    |> Keyword.get(:base_retry_delay, 30)
  @first_retry_delay_range @base_retry_delay..(@base_retry_delay + div(@base_retry_delay, 10) + 1)

  defmodule QueryCapturingRepo do
    @moduledoc false
    # Stands in for the repo passed to `claim_batch_for_processing/3` so a test
    # can inspect the UPDATE query it builds instead of executing it.
    def update_all(query, _updates) do
      send(self(), {:update_all_query, query})
      {0, []}
    end
  end

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

    test "claims pending and retryable commands with their respective retry counts", %{
      instance: instance
    } do
      {:ok, pending} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      retryable = seed_occ_timeout_command(instance, 2)

      claimed = Scheduling.claim_batch_for_processing([retryable, pending], "proc-1")

      assert Enum.map(claimed, & &1.id) == [retryable.id, pending.id]
      assert Enum.map(claimed, & &1.command_queue_item.retry_count) == [3, 0]
      assert Enum.all?(claimed, &(&1.command_queue_item.status == :processing))
    end

    test "does not claim a retry that has been rescheduled for the future", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 2)
      next_retry_after = DateTime.add(DateTime.utc_now(), 3_600, :second)

      command.command_queue_item
      |> Changeset.change(%{next_retry_after: next_retry_after})
      |> Repo.update!()

      command = CommandStore.get_by_id(command.id)

      assert [] = Scheduling.claim_batch_for_processing([command], "proc-1")

      queue_item = CommandStore.get_by_id(command.id).command_queue_item
      assert queue_item.status == :occ_timeout
      assert queue_item.retry_count == 2
      assert queue_item.next_retry_after == next_retry_after
    end

    test "claims a retry whose next_retry_after is in the database's past", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 2)
      reschedule_retry_relative_to_db_clock(command.id, -1)
      command = CommandStore.get_by_id(command.id)

      [%Command{command_queue_item: qi}] =
        Scheduling.claim_batch_for_processing([command], "proc-1")

      assert qi.status == :processing
      assert qi.retry_count == 3
      assert qi.next_retry_after == nil
    end

    test "does not claim a retry whose next_retry_after is in the database's future", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 2)
      reschedule_retry_relative_to_db_clock(command.id, 1)
      command = CommandStore.get_by_id(command.id)

      assert [] = Scheduling.claim_batch_for_processing([command], "proc-1")
      assert CommandStore.get_by_id(command.id).command_queue_item.status == :occ_timeout
    end

    test "evaluates retry eligibility on the database clock, not an application timestamp", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 0)

      assert [] = Scheduling.claim_batch_for_processing([command], "proc-1", QueryCapturingRepo)
      assert_receive {:update_all_query, query}

      {sql, params} = Ecto.Adapters.SQL.to_sql(:update_all, Repo, query)

      # The comparison happens in SQL; no BEAM-side timestamp is bound.
      assert sql =~ "timezone('UTC', statement_timestamp())"
      refute Enum.any?(params, &match?(%DateTime{}, &1))
      refute Enum.any?(params, &match?(%NaiveDateTime{}, &1))
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

    test "emits a command_claim telemetry event per claimed command", %{instance: instance} do
      c1 = seed_occ_timeout_command(instance, 0)
      c2 = seed_occ_timeout_command(instance, 0)

      ref = attach_telemetry([:double_entry_ledger, :command, :claim])

      Scheduling.claim_batch_for_processing([c1, c2], "proc-1")

      # Same claim event the single-command path emits, one per command.
      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim], _m,
                      %{command_id: id_a, processor_id: "proc-1"}}

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim], _m,
                      %{command_id: id_b, processor_id: "proc-1"}}

      assert MapSet.new([id_a, id_b]) == MapSet.new([c1.id, c2.id])
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

    test "rejects completion from an owner whose claim version is stale", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, claimed_by_old_owner} =
        Scheduling.claim_command_for_processing(command.id, "old-owner")

      claimed_by_old_owner.command_queue_item
      |> Changeset.change(processor_id: "new-owner")
      |> Changeset.optimistic_lock(:processor_version)
      |> Repo.update!()

      assert_raise Ecto.StaleEntryError, fn ->
        claimed_by_old_owner
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()
      end

      current = CommandStore.get_by_id(command.id).command_queue_item
      assert current.status == :processing
      assert current.processor_id == "new-owner"
    end

    test "builds changeset to mark command as processed", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_mark_as_processed(command)

      assert command_queue_item.valid?
      assert command_queue_item.changes.status == :processed
      refute Changeset.changed?(command_queue_item, :processing_completed_at)
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
      refute Changeset.changed?(command_queue_item, :processing_completed_at)
      assert Ecto.Changeset.get_field(command_queue_item, :next_retry_after) == nil
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == error end)
    end

    test "logs at error level after dead-lettering is persisted", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      log =
        capture_log([level: :error], fn ->
          assert {:error, %{command_queue_item: %{status: :dead_letter}}} =
                   Scheduling.mark_as_dead_letter(command, "Terminal failure")
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
      assert is_integer(command_queue_item.changes.retry_delay_seconds)
      assert command_queue_item.changes.retry_delay_seconds > 0
      refute Map.has_key?(command_queue_item.changes, :next_retry_after)
      refute Changeset.changed?(command_queue_item, :processing_completed_at)
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == error end)
    end

    test "persists a next_retry_after computed by the database from the delay", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:error, %{command_queue_item: returned}} =
        Scheduling.schedule_retry_with_reason(command, "retry reason", :failed)

      reloaded = Repo.get!(CommandQueueItem, command.command_queue_item.id)

      # The delay is a transient instruction to the trigger, never persisted.
      assert returned.retry_delay_seconds == nil
      assert reloaded.retry_delay_seconds == nil

      # Both timestamps are stamped by the trigger from the same database
      # clock reading, so they differ by exactly the delay.
      assert returned.next_retry_after == reloaded.next_retry_after
      delay = DateTime.diff(reloaded.next_retry_after, reloaded.processing_completed_at, :second)
      assert delay in @first_retry_delay_range
    end

    test "logs the reason after a retry is persisted", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      log =
        capture_log([level: :warning], fn ->
          assert {:error, %{command_queue_item: %{status: :failed}}} =
                   Scheduling.schedule_retry_with_reason(command, "retry reason", :failed)
        end)

      assert log =~ "command #{command.id} persisted with failed status"
      assert log =~ "retry reason"
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
      refute Changeset.changed?(command_queue_item, :processing_completed_at)
      assert Changeset.get_field(command_queue_item, :retry_count) == 0
      assert Enum.any?(command_queue_item.changes.errors, fn e -> e.message == test_message end)
    end

    test "derives next_retry_after from the create command's database-written retry time",
         %{instance: instance} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      {:error, failed_create_command} =
        Scheduling.schedule_retry_with_reason(pending_command, "some reason", :failed)

      create_next_retry_after = failed_create_command.command_queue_item.next_retry_after
      assert %DateTime{} = create_next_retry_after

      {:ok, command} = new_update_transaction_command(s, s_id, instance.address, :posted)

      error = %UpdateCommandError{
        create_command: failed_create_command,
        update_command: command,
        message: "Test error",
        reason: :create_command_not_processed
      }

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_schedule_update_retry(command, error)

      # The base is a database-produced timestamp, so the changeset carries
      # the derived timestamp and no delay instruction.
      refute Map.has_key?(command_queue_item.changes, :retry_delay_seconds)
      derived = command_queue_item.changes.next_retry_after
      assert DateTime.diff(derived, create_next_retry_after, :second) in @first_retry_delay_range
    end

    test "supplies only a delay when the create command has no retry time",
         %{instance: instance} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      assert pending_command.command_queue_item.next_retry_after == nil

      {:ok, command} = new_update_transaction_command(s, s_id, instance.address, :posted)

      error = %UpdateCommandError{
        create_command: pending_command,
        update_command: command,
        message: "Test error",
        reason: :create_command_not_processed
      }

      %{changes: %{command_queue_item: command_queue_item}} =
        Scheduling.build_schedule_update_retry(command, error)

      # No application clock involved: the trigger computes next_retry_after.
      refute Map.has_key?(command_queue_item.changes, :next_retry_after)
      assert command_queue_item.changes.retry_delay_seconds in @first_retry_delay_range
    end
  end

  describe "next_command_ids_query/2" do
    test "evaluates retry eligibility on the database clock" do
      query = Scheduling.next_command_ids_query(Ecto.UUID.generate(), 10)

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

      assert sql =~ "timezone('UTC', statement_timestamp())"
      refute Enum.any?(params, &match?(%DateTime{}, &1))
      refute Enum.any?(params, &match?(%NaiveDateTime{}, &1))
    end
  end

  describe "instances_with_processable_commands_query/0" do
    test "evaluates retry eligibility on the database clock" do
      query = Scheduling.instances_with_processable_commands_query()

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

      assert sql =~ "timezone('UTC', statement_timestamp())"
      refute Enum.any?(params, &match?(%DateTime{}, &1))
      refute Enum.any?(params, &match?(%NaiveDateTime{}, &1))
    end
  end
end
