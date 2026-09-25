defmodule DoubleEntryLedger.CommandQueue.SchedulingTest do
  @moduledoc """
  Tests for the scheduling of commands in the command queue.
  """
  # Not async: the lease tests here put global application config
  # (`put_queue_config/1`) and need the shared sandbox so a `Task` can reach
  # the database, exactly like `DoubleEntryLedger.CommandQueue.LeaseTest`.
  use DoubleEntryLedger.RepoCase, async: false
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL
  alias Ecto.Changeset
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.LeaseFixtures
  alias DoubleEntryLedger.{Command, CommandQueueItem, CommandQueueLeaseRow}
  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError

  @prefix DoubleEntryLedger.Config.schema_prefix()

  # `Scheduling.calculate_retry_delay/1` for retry_count 0: base delay plus a
  # jitter of 1..(base/10 + 1) seconds.
  @base_retry_delay Application.compile_env(
                      :double_entry_ledger,
                      [:command_queue, :base_retry_delay],
                      30
                    )
  @first_retry_delay_range @base_retry_delay..(@base_retry_delay + div(@base_retry_delay, 10) + 1)

  # `Scheduling.reschedule_orphaned_processing!/2`'s dead-letter boundary.
  @max_retries Application.compile_env(:double_entry_ledger, [:command_queue, :max_retries], 5)

  defp mark_processing(command, processor_id) do
    {1, _} =
      Repo.update_all(
        from(q in CommandQueueItem, where: q.command_id == ^command.id),
        set: [status: :processing, processor_id: processor_id]
      )

    :ok
  end

  defmodule RaisesOnSecondWriteRepo do
    @moduledoc false
    # Loads normally and delegates the first write to the real Repo, so it
    # really lands, then raises on every write after that. A test can use
    # this to prove that a later failure rolls back an earlier write that
    # already succeeded inside the same caller transaction. State lives in
    # the process dictionary of the (single, synchronous) caller process,
    # not in the test body.
    def all(query), do: DoubleEntryLedger.Repo.all(query)

    def update!(changeset) do
      if Process.get(__MODULE__) do
        raise Postgrex.Error, message: "simulated write failure"
      else
        Process.put(__MODULE__, true)
        DoubleEntryLedger.Repo.update!(changeset)
      end
    end
  end

  defmodule QueryCapturingRepo do
    @moduledoc false
    # The claim runs in a transaction with lease statements. Delegate all
    # of it except the command_queue_items UPDATE, which is captured.
    alias DoubleEntryLedger.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def in_transaction?, do: Repo.in_transaction?()
    def query!(sql, params), do: Repo.query!(sql, params)

    def update_all(%Ecto.Query{from: %{source: {"command_queue_items", _}}} = query, _updates) do
      send(self(), {:update_all_query, query})
      {0, []}
    end

    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  defmodule StatementOrderRepo do
    @moduledoc false
    # Delegates everything, recording the table each `update_all/2` touches, so
    # a test can pin the ordering the whole lease design rests on: the lease
    # row UPDATE (`Lease.lock!/3`) first and last, the claim UPDATE between
    # them. Both lease statements issue the same query, so only their position
    # in the sequence tells them apart.
    alias DoubleEntryLedger.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def in_transaction?, do: Repo.in_transaction?()
    def query!(sql, params), do: Repo.query!(sql, params)

    def update_all(%Ecto.Query{from: %{source: {table, _}}} = query, updates) do
      send(self(), {:update_all_table, table})
      Repo.update_all(query, updates)
    end
  end

  describe "claim_command_for_processing/2" do
    setup [:create_instance, :create_accounts]

    test "returns error when command not found", %{instance: instance} do
      grant = test_grant(instance.id)

      assert {:error, :command_not_found} =
               Scheduling.claim_command_for_processing(Ecto.UUID.generate(), grant)
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
               Scheduling.claim_command_for_processing(command.id, test_grant(instance.id))
    end

    test "claims a command for processing", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      grant = test_grant(instance.id)

      assert {:ok, %Command{command_queue_item: eqm} = claimed_command} =
               Scheduling.claim_command_for_processing(command.id, grant)

      assert eqm.status == :processing
      assert eqm.command_id == claimed_command.id
      assert eqm.processor_id == grant.owner_id
      assert eqm.processing_started_at != nil
      assert eqm.processing_completed_at == nil
      assert eqm.retry_count == 0
      assert eqm.next_retry_after == nil
    end

    test "does not claim a retry whose next_retry_after is in the database's future", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 2)
      reschedule_retry_relative_to_db_clock(command.id, 1)

      assert {:error, :command_not_claimable} =
               Scheduling.claim_command_for_processing(command.id, test_grant(instance.id))

      current = CommandStore.get_by_id(command.id).command_queue_item
      assert current.status == :occ_timeout
      assert current.processor_id == nil
      assert current.retry_count == 2
    end

    test "claims a retry whose next_retry_after is in the database's past", %{instance: instance} do
      command = seed_occ_timeout_command(instance, 2)
      reschedule_retry_relative_to_db_clock(command.id, -1)
      grant = test_grant(instance.id)

      assert {:ok, %Command{command_queue_item: qi}} =
               Scheduling.claim_command_for_processing(command.id, grant)

      assert qi.status == :processing
      assert qi.retry_count == 3
      assert qi.next_retry_after == nil
      assert qi.processor_id == grant.owner_id
    end

    test "does not claim a :pending command whose dependency wait has not elapsed", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 0)
      reschedule_retry_relative_to_db_clock(command.id, 1)

      command.command_queue_item
      |> Changeset.change(%{status: :pending})
      |> Repo.update!()

      assert {:error, :command_not_claimable} =
               Scheduling.claim_command_for_processing(command.id, test_grant(instance.id))

      current = CommandStore.get_by_id(command.id).command_queue_item
      assert current.status == :pending
      assert current.processor_id == nil
    end

    test "emits exactly one claim telemetry event for a successful claim", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command_id = command.id
      grant = test_grant(instance.id)
      owner_id = grant.owner_id
      ref = attach_telemetry([:double_entry_ledger, :command, :claim])

      assert {:ok, _claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim], _m,
                      %{command_id: ^command_id, processor_id: ^owner_id}}

      refute_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim], _m2,
                      %{command_id: ^command_id}},
                     50
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
      grant = test_grant(instance.id)

      {:ok, %Command{command_queue_item: single_qi}} =
        Scheduling.claim_command_for_processing(single.id, grant)

      [%Command{command_queue_item: batch_qi}] =
        Scheduling.claim_batch_for_processing([batched], grant)

      assert single_qi.status == :processing
      assert batch_qi.status == :processing

      # Re-claim of a non-:pending command bumps retry_count 2 → 3 in both.
      assert single_qi.retry_count == 3
      assert batch_qi.retry_count == 3

      assert single_qi.processor_id == grant.owner_id
      assert batch_qi.processor_id == grant.owner_id

      assert single_qi.next_retry_after == nil
      assert batch_qi.next_retry_after == nil

      assert single_qi.processing_started_at != nil
      assert batch_qi.processing_started_at != nil

      assert single_qi.processing_completed_at == nil
      assert batch_qi.processing_completed_at == nil
    end

    test "leaves retry_count unchanged when claiming a :pending command", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command = CommandStore.get_by_id(command.id)

      [%Command{command_queue_item: qi}] =
        Scheduling.claim_batch_for_processing([command], test_grant(instance.id))

      assert qi.status == :processing
      assert qi.retry_count == 0
    end

    test "claims pending and retryable commands with their respective retry counts", %{
      instance: instance
    } do
      {:ok, pending} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      retryable = seed_occ_timeout_command(instance, 2)

      claimed =
        Scheduling.claim_batch_for_processing([retryable, pending], test_grant(instance.id))

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

      assert [] = Scheduling.claim_batch_for_processing([command], test_grant(instance.id))

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
        Scheduling.claim_batch_for_processing([command], test_grant(instance.id))

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

      assert [] = Scheduling.claim_batch_for_processing([command], test_grant(instance.id))
      assert CommandStore.get_by_id(command.id).command_queue_item.status == :occ_timeout
    end

    test "evaluates retry eligibility on the database clock, not an application timestamp", %{
      instance: instance
    } do
      command = seed_occ_timeout_command(instance, 0)
      grant = test_grant(instance.id)

      assert [] = Scheduling.claim_batch_for_processing([command], grant, QueryCapturingRepo)
      assert_receive {:update_all_query, query}

      {sql, params} = SQL.to_sql(:update_all, Repo, query)

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

      claimed =
        Scheduling.claim_batch_for_processing([claimable, not_claimable], test_grant(instance.id))

      assert Enum.map(claimed, & &1.id) == [claimable.id]
    end

    test "emits a command_claim telemetry event per claimed command", %{instance: instance} do
      c1 = seed_occ_timeout_command(instance, 0)
      c2 = seed_occ_timeout_command(instance, 0)
      grant = test_grant(instance.id)
      owner_id = grant.owner_id

      ref = attach_telemetry([:double_entry_ledger, :command, :claim])

      Scheduling.claim_batch_for_processing([c1, c2], grant)

      # Same claim event the single-command path emits, one per command.
      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim], _m,
                      %{command_id: id_a, processor_id: ^owner_id}}

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim], _m,
                      %{command_id: id_b, processor_id: ^owner_id}}

      assert MapSet.new([id_a, id_b]) == MapSet.new([c1.id, c2.id])
    end
  end

  describe "claims under a lease" do
    setup [:create_instance, :create_accounts]

    test "claim stamps the grant's owner_id, sets lease_grant, and refreshes expiry", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      grant = test_grant(instance.id)
      before = lease_row(instance.id)

      assert {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert claimed.command_queue_item.processor_id == grant.owner_id
      assert claimed.lease_grant == grant

      # Against `before.renewed_at`, not `before.acquired_at`: `test_grant/1`
      # acquires through `Lease.acquire/4`, which already ends in
      # `refresh_locked!/3`, so `renewed_at` is non-nil and >= `acquired_at`
      # before the claim runs. Only a strict advance on `renewed_at` proves the
      # claim transaction issued an owner update of its own.
      assert DateTime.compare(lease_row(instance.id).renewed_at, before.renewed_at) == :gt
    end

    test "claim after a takeover returns {:error, :lease_lost} and leaves the row pending", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      old = test_grant(instance.id)
      expire_lease(instance.id)
      _new = test_grant(instance.id)

      assert {:error, :lease_lost} = Scheduling.claim_command_for_processing(command.id, old)
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :pending
    end

    test "runs the claim between a lease lock and a lease refresh", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command = CommandStore.get_by_id(command.id)
      grant = test_grant(instance.id)

      assert [_claimed] =
               Scheduling.claim_batch_for_processing([command], grant, StatementOrderRepo)

      assert update_all_tables(4) == [
               "command_queue_leases",
               "command_queue_items",
               "command_queue_leases",
               :nothing_more
             ]
    end

    test "refuses to claim inside a caller's transaction", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command = CommandStore.get_by_id(command.id)
      grant = test_grant(instance.id)

      # `Lease.with_grant/3`'s guard. Without it `repo.transaction/1` would
      # join the caller's transaction, the lease lock would no longer be its
      # first statement, and the claim would silently run unfenced.
      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Scheduling.claim_batch_for_processing([command], grant) end)
      end

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :pending
    end

    # The probe can only contend for a row it can see, so these two tests own a
    # `committed_lease/3` ledger instead of the sandbox `instance`.
    test "claim while the probe holds the lease row past the timeout returns {:error, :lease_busy}" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "holder", 1)
      {:ok, command} = create_command_on(grant.instance_id)
      hold_lock_on_probe(probe, grant)

      assert {:error, :lease_busy} = Scheduling.claim_command_for_processing(command.id, grant)
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :pending
    end

    # Deliberately does NOT call `Scheduling`: the probe stands in for the
    # claim's statement sequence, because the real claim runs on the sandbox
    # connection and a second sandbox process cannot contend with it. It pins
    # the lease serialization an open claim relies on, not the claim itself, so
    # it will keep passing however `claim_batch_for_processing/3` is reordered
    # or broken — the statement-order test above is what covers that. Keep the
    # probe's statements in step with `claim_batch_for_processing/3` if the
    # claim's shape changes.
    test "an acquire waits behind a probe standing in for an open claim that then rolls back" do
      put_queue_config(lease_lock_timeout_ms: 5_000)
      probe = probe_connection()
      grant = committed_lease(probe, "claimer", 1)
      command_id = committed_command(probe, grant.instance_id)
      expire_lease_on_probe(probe, grant)
      hold_lock_on_probe(probe, grant)

      %Postgrex.Result{num_rows: 1} =
        Postgrex.query!(
          probe,
          "UPDATE #{@prefix}.command_queue_items " <>
            "SET status = 'processing', processor_id = $2 WHERE command_id = $1",
          [Ecto.UUID.dump!(command_id), grant.owner_id]
        )

      task = Task.async(fn -> Lease.acquire(grant.instance_id, "successor") end)
      assert Task.yield(task, 300) == nil

      rollback_probe(probe)

      assert {:ok, _grant, %{orphans: []}} = Task.await(task, 5_000)
      assert Repo.get_by(CommandQueueItem, command_id: command_id).status == :pending
    end
  end

  # The first `count` tables `StatementOrderRepo` recorded, in mailbox order,
  # padded with `:nothing_more` once the claim has issued its last statement.
  # `assert_receive` cannot pin an order: it scans the mailbox for a match and
  # skips past anything that does not fit, so a reordered claim still satisfies
  # a sequence of them.
  defp update_all_tables(count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:update_all_table, table} -> table
      after
        200 -> :nothing_more
      end
    end)
  end

  # The inverse of `LeaseFixtures.expire_lease/1`: moves the expiry an hour
  # into the database's future and touches nothing else.
  defp unexpire_lease(instance_id) do
    {1, _} =
      from(l in CommandQueueLeaseRow,
        where: l.instance_id == ^instance_id,
        update: [
          set: [expires_at: fragment("timezone('UTC', clock_timestamp()) + interval '1 hour'")]
        ]
      )
      |> Repo.update_all([])

    :ok
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

    # The queue row is not a boundary: the `commands` row beside it already holds
    # the whole command_map, and `Command`'s Jason encoder serialises the two
    # together, so the full message there is redundant rather than a leak — and
    # it is the column operators read. A telemetry event IS a boundary: it
    # reaches whatever exporter the host attached and carries no payload of its
    # own, so this string is the only route out. The event gets the type; the
    # detail stays on the row, behind database access.
    test "the dead-letter event carries the failure type, not the detail", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      ref = attach_telemetry([:double_entry_ledger, :command, :dead_letter])

      assert {:error, _updated} =
               Scheduling.mark_as_dead_letter(
                 command,
                 "Task crashed: MatchError: no match of right hand side value: %{amount: 4200}"
               )

      assert_receive {:telemetry_event, ^ref, _event, _measurements, %{error: error}}
      assert error == "Task crashed"
      refute error =~ "4200"

      assert [%{"message" => persisted} | _] =
               CommandStore.get_by_id(command.id).command_queue_item.errors

      assert persisted =~ "4200"
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

  # A queue row whose newest error is not an entry `ErrorMap.build_error/2`
  # built means the write that was supposed to record a failure did not. Before
  # `:class` existed the narrow head made that a FunctionClauseError; it still
  # does. `emit_persisted_failure/3` is public and runs after the write already
  # committed, so it cannot raise — it logs instead of returning `:ok` as if the
  # event had fired.
  describe "a failure whose error entry is not an ErrorMap entry" do
    setup [:create_instance, :create_accounts]

    # Reloaded rather than hand-built: a row read back from PostgreSQL carries
    # its errors as string-keyed maps, which is exactly the "loaded from the
    # database and not re-prepended" case.
    test "persisted_failure/1 raises on a reloaded row's string-keyed entry", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:error, _} = Scheduling.schedule_retry_with_reason(command, "boom", :failed)
      reloaded = CommandStore.get_by_id(command.id)

      assert_raise FunctionClauseError, ~r/persisted_failure/, fn ->
        Scheduling.persisted_failure(reloaded)
      end
    end

    test "persisted_failure/1 raises on a queue row with no errors at all", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      command.command_queue_item
      |> Changeset.change(%{status: :failed, errors: []})
      |> Repo.update!()

      assert_raise FunctionClauseError, ~r/persisted_failure/, fn ->
        Scheduling.persisted_failure(CommandStore.get_by_id(command.id))
      end
    end

    test "emit_persisted_failure/3 emits no retry event", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      ref = attach_telemetry([:double_entry_ledger, :command, :retry])

      capture_log(fn ->
        Scheduling.emit_persisted_failure(command, :failed, %{"message" => "boom"})
      end)

      refute_received {:telemetry_event, ^ref, _event, _measurements, _metadata}
    end

    test "emit_persisted_failure/3 says so at error level", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      log =
        capture_log([level: :error], fn ->
          Scheduling.emit_persisted_failure(command, :failed, %{"message" => "boom"})
        end)

      assert log =~ "no failed telemetry emitted for command #{command.id}"
    end

    test "emit_persisted_failure/3 does not log the entry it could not read", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      log =
        capture_log([level: :error], fn ->
          Scheduling.emit_persisted_failure(command, :dead_letter, %{"message" => "4200"})
        end)

      refute log =~ "4200"
    end

    test "a status that is not a failure transition stays a silent :ok", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      log =
        capture_log([level: :error], fn ->
          assert Scheduling.emit_persisted_failure(command, :processed, %{"message" => "boom"}) ==
                   :ok
        end)

      assert log == ""
    end
  end

  describe "build_revert_to_pending/2" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to revert command to pending", %{instance: instance} do
      {:ok, pending_command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, command} =
        Scheduling.claim_command_for_processing(pending_command.id, test_grant(instance.id))

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

  describe "build_schedule_retry_with_reason/4 with retry_delay: 0" do
    setup [:create_instance, :create_accounts]

    test "writes a zero delay so the row is eligible at once", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, updated} =
        command
        |> Scheduling.build_schedule_retry_with_reason("orphaned", :failed, retry_delay: 0)
        |> Repo.update()

      assert updated.command_queue_item.status == :failed
      assert [updated.id] == Repo.all(Scheduling.next_command_ids_query(instance.id, 10))
    end
  end

  describe "reschedule_orphaned_processing!/2" do
    setup [:create_instance, :create_accounts]

    test "reschedules every :processing row regardless of processor_id, in position order", %{
      instance: instance
    } do
      {:ok, first} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "one")
        )

      {:ok, second} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "two")
        )

      mark_processing(first, "legacy-a")
      mark_processing(second, "legacy-b")

      {:ok, orphans} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert Enum.map(orphans, fn {command, _previous} -> command.id end) ==
               [first.id, second.id]

      assert Enum.map(orphans, fn {_command, previous} -> previous end) ==
               ["legacy-a", "legacy-b"]

      assert Enum.all?(orphans, fn {c, _} -> c.command_queue_item.status == :failed end)
      assert Enum.all?(orphans, fn {c, _} -> is_nil(c.command_queue_item.processor_id) end)
      assert Repo.all(Scheduling.next_command_ids_query(instance.id, 10)) == [first.id, second.id]
    end

    test "returns rows in queue position order even when marked :processing in reverse order",
         %{instance: instance} do
      {:ok, first} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "one")
        )

      {:ok, second} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "two")
        )

      {:ok, third} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "three")
        )

      mark_processing(third, "legacy-c")
      mark_processing(second, "legacy-b")
      mark_processing(first, "legacy-a")

      {:ok, orphans} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert Enum.map(orphans, fn {command, _previous} -> command.id end) ==
               [first.id, second.id, third.id]
    end

    test "does not touch another instance's :processing row", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      mark_processing(command, "legacy-a")

      other_instance = instance_fixture(address: "other:instance:address")

      {:ok, other_command} =
        CommandStore.create(transaction_command_attrs(instance_address: other_instance.address))

      mark_processing(other_command, "other-node")

      {:ok, orphans} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert Enum.map(orphans, fn {orphan, _previous} -> orphan.id end) == [command.id]

      untouched = Repo.get_by(CommandQueueItem, command_id: other_command.id)
      assert untouched.status == :processing
      assert untouched.processor_id == "other-node"
      assert untouched.retry_count == 0
      assert untouched.errors == []
      assert untouched.next_retry_after == nil
    end

    test "records the previous processor in the error", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      mark_processing(command, "legacy-a")

      {:ok, [{orphan, _previous}]} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert hd(orphan.command_queue_item.errors).message =~ "legacy-a"
      assert hd(orphan.command_queue_item.errors).message =~ "orphaned by lease acquisition"
    end

    # The id is returned as data rather than left for the caller to recover
    # from the sentence above: the reschedule nulls `processor_id` on the row,
    # so this is the caller's only source for it.
    test "returns the previous processor id beside the command", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      mark_processing(command, "legacy-a")

      {:ok, [{orphan, previous}]} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert previous == "legacy-a"
      assert orphan.command_queue_item.processor_id == nil
    end

    test "returns a nil previous processor for a row that carried none", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      mark_processing(command, nil)

      {:ok, [{_orphan, previous}]} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert previous == nil
    end

    test "dead-letters an orphan already at max retries", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      mark_processing(command, "legacy-a")

      Repo.update_all(
        from(q in CommandQueueItem, where: q.command_id == ^command.id),
        set: [retry_count: @max_retries]
      )

      {:ok, [{orphan, _previous}]} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)

      assert orphan.command_queue_item.status == :dead_letter
    end

    test "returns [] when nothing is :processing", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      {:ok, []} =
        Repo.transaction(fn -> Scheduling.reschedule_orphaned_processing!(instance.id, Repo) end)
    end

    test "rolls back an earlier successful write when a later write in the same call fails", %{
      instance: instance
    } do
      {:ok, first} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "one")
        )

      {:ok, second} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "two")
        )

      mark_processing(first, "legacy-a")
      mark_processing(second, "legacy-b")

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Scheduling.reschedule_orphaned_processing!(instance.id, RaisesOnSecondWriteRepo)
        end)
      end

      assert Repo.get_by(CommandQueueItem, command_id: first.id).status == :processing
      assert Repo.get_by(CommandQueueItem, command_id: second.id).status == :processing
    end
  end

  describe "build_schedule_update_retry" do
    setup [:create_instance, :create_accounts]

    test "builds changeset to schedule update_retry", %{instance: instance} = ctx do
      %{command: %{command_map: %{source: s, source_idempk: s_id}} = pending_command} =
        new_create_transaction_command(ctx, :pending)

      {:error, failed_create_command} =
        Scheduling.schedule_retry_with_reason(
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

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ "timezone('UTC', statement_timestamp())"
      refute Enum.any?(params, &match?(%DateTime{}, &1))
      refute Enum.any?(params, &match?(%NaiveDateTime{}, &1))
    end
  end

  describe "instances_with_processable_commands_query/0" do
    test "evaluates retry eligibility on the database clock" do
      query = Scheduling.instances_with_processable_commands_query()

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ "timezone('UTC', statement_timestamp())"
      refute Enum.any?(params, &match?(%DateTime{}, &1))
      refute Enum.any?(params, &match?(%NaiveDateTime{}, &1))
    end
  end

  describe "instances_with_processable_commands_query/0 with leases" do
    setup [:create_instance, :create_accounts]

    test "includes a ledger with work and no lease", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert instance.id in Repo.all(Scheduling.instances_with_processable_commands_query())
    end

    test "excludes a ledger with a live lease", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      _grant = test_grant(instance.id)
      refute instance.id in Repo.all(Scheduling.instances_with_processable_commands_query())
    end

    test "includes a ledger with an expired lease", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      _grant = test_grant(instance.id)
      expire_lease(instance.id)
      assert instance.id in Repo.all(Scheduling.instances_with_processable_commands_query())
    end

    test "includes a ledger whose only row is :processing under an expired lease", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      grant = test_grant(instance.id)
      {:ok, _} = Scheduling.claim_command_for_processing(command.id, grant)
      expire_lease(instance.id)

      assert instance.id in Repo.all(Scheduling.instances_with_processable_commands_query())
    end

    test "includes a ledger whose lease was released", %{instance: instance} do
      {:ok, _} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      grant = test_grant(instance.id)

      assert :ok = Lease.release(grant, :drained)

      # `Lease.release/3` stamps `expires_at` and `released_at` in one
      # statement, so an expiry-only predicate would surface this ledger by
      # accident. Pushing the expiry back out leaves `released_at` as the only
      # reason it can be offered, which is the clause under test.
      unexpire_lease(instance.id)

      assert instance.id in Repo.all(Scheduling.instances_with_processable_commands_query())
    end

    test "binds no application timestamp" do
      {sql, params} =
        SQL.to_sql(:all, Repo, Scheduling.instances_with_processable_commands_query())

      assert sql =~ "command_queue_leases"
      assert sql =~ "statement_timestamp()"
      refute Enum.any?(params, &match?(%DateTime{}, &1))
      refute Enum.any?(params, &match?(%NaiveDateTime{}, &1))
    end
  end
end
