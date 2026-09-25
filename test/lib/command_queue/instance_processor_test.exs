defmodule DoubleEntryLedger.CommandQueue.InstanceProcessorTest do
  @moduledoc """
  Tests for the InstanceProcessor GenServer crash recovery via Process.monitor.

  Uses a mock CommandWorker injected into the real InstanceProcessor to control
  task behavior and verify the full processing lifecycle.
  """
  use DoubleEntryLedger.RepoCase, async: false
  import Mox

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.LeaseFixtures

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Command.TransactionData
  alias DoubleEntryLedger.CommandQueue.{InstanceProcessor, Scheduling}
  alias DoubleEntryLedger.{CommandQueueItem, Repo}
  alias DoubleEntryLedger.Stores.CommandStore

  # ── Test stub modules for the batch path ─────────────────────────
  #
  # These stand in for `BatchProcessor` so we can:
  #   * record the commands the InstanceProcessor passed in (without
  #     touching the real DB write path),
  #   * inject specific outcome shapes,
  #   * crash on demand to exercise the :DOWN handler.
  #
  # Each module exposes `run_batch/1` (and /2 default-arity matching
  # `BatchProcessor`'s public surface).

  defmodule SuccessBatchProcessor do
    # Sends the list of command IDs it received to the test pid via
    # the registered name `:batch_processor_test_observer`, then
    # returns a synthesized success outcome for every command.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      send(:batch_processor_test_observer, {:batch_run_received, Enum.map(commands, & &1.id)})

      complete(commands)
    end

    def complete(commands) do
      successes =
        Enum.map(commands, fn cmd ->
          %{command_id: cmd.id, transaction_id: Ecto.UUID.generate()}
        end)

      # Mark queue rows :processed so the InstanceProcessor's claim
      # query stops returning them and the GenServer shuts down.
      Enum.each(commands, fn cmd ->
        cmd
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()
      end)

      {:ok, %{successes: successes, failures: []}}
    end
  end

  defmodule BlockingSuccessBatchProcessor do
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      send(
        :batch_processor_test_observer,
        {:blocking_batch_started, self(), Enum.map(commands, & &1.id)}
      )

      receive do
        :continue -> SuccessBatchProcessor.complete(commands)
      after
        5_000 -> raise "timed out waiting to continue batch"
      end
    end
  end

  defmodule CrashBatchProcessor do
    # Always raises — exercises the InstanceProcessor batch :DOWN handler.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      send(:batch_processor_test_observer, {:batch_run_received, Enum.map(commands, & &1.id)})
      raise "batch crash boom"
    end
  end

  defmodule PartialCommitCrashBatchProcessor do
    def run_batch([committed | _] = commands, _repo \\ DoubleEntryLedger.Repo) do
      committed
      |> Scheduling.build_mark_as_processed()
      |> Repo.update!()

      send(
        :batch_processor_test_observer,
        {:partial_batch_crashed, committed.id, Enum.map(commands, & &1.id)}
      )

      raise "crash after partial commit"
    end
  end

  defmodule OwnershipLostCrashBatchProcessor do
    # Moves the claim to another processor and then crashes, so the cleanup
    # that follows has to notice the row is no longer this owner's
    # (`CommandQueue.Cleanup.reload_if_still_mine/3`) and leave it alone.
    def run_batch([stolen | _] = commands, _repo \\ DoubleEntryLedger.Repo) do
      stolen.command_queue_item
      |> Ecto.Changeset.change(processor_id: "replacement-owner")
      |> Repo.update!()

      send(
        :batch_processor_test_observer,
        {:batch_ownership_lost, stolen.id, Enum.map(commands, & &1.id)}
      )

      raise "crash after ownership changed"
    end
  end

  defmodule DbErrorBatchProcessor do
    # Simulates a non-stale DB error from the batched write (e.g. an
    # unexpected Postgrex/constraint error). Per the plan (§8.3) the caller
    # must roll back and fall back to per-command processing for this batch,
    # so worst-case is no worse than the single-cmd path. With the fallback
    # wired up this is reached exactly once — the batch's commands are then
    # drained through the single-cmd worker path.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      send(:batch_processor_test_observer, {:batch_run_received, Enum.map(commands, & &1.id)})
      {:error, %Postgrex.Error{message: "simulated non-stale DB error"}}
    end
  end

  defmodule ToggleOffBatchProcessor do
    # Processes its commands as a successful batch, but first flips
    # :batch_enabled OFF as a side effect — so the next :process_next round
    # on the SAME running processor must fall through to the legacy
    # single-cmd path. Proves the flag is read live (per cycle), not cached
    # at init.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      Application.put_env(:double_entry_ledger, :batch_enabled, false)
      send(:batch_processor_test_observer, {:batch_run_received, Enum.map(commands, & &1.id)})

      successes =
        Enum.map(commands, fn cmd ->
          cmd
          |> Scheduling.build_mark_as_processed()
          |> Repo.update!()

          %{command_id: cmd.id, transaction_id: Ecto.UUID.generate()}
        end)

      {:ok, %{successes: successes, failures: []}}
    end
  end

  defmodule LeaseLostBatchProcessor do
    def run_batch(_commands, _repo \\ DoubleEntryLedger.Repo), do: {:error, :lease_lost}
  end

  defmodule LeaseBusyOnceBatchProcessor do
    alias DoubleEntryLedger.CommandQueue.InstanceProcessorTest.SuccessBatchProcessor

    # First call reports busy; the retry (a fresh task) completes the batch.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      key = {DoubleEntryLedger.CommandQueue.InstanceProcessorTest, :busy_done}
      first_call? = not :persistent_term.get(key)
      :persistent_term.put(key, true)
      outcome_for(first_call?, commands)
    end

    defp outcome_for(true, _commands), do: {:error, :lease_busy}

    defp outcome_for(false, commands), do: SuccessBatchProcessor.complete(commands)
  end

  defmodule SilentSuccessBatchProcessor do
    alias DoubleEntryLedger.CommandQueue.InstanceProcessorTest.SuccessBatchProcessor

    # `SuccessBatchProcessor` without the observer `send/2`, for tests that do
    # not register the observer name and must not reach the batch at all.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo),
      do: SuccessBatchProcessor.complete(commands)
  end

  defmodule CommitThenCrashBatchProcessor do
    alias DoubleEntryLedger.CommandQueue.InstanceProcessorTest.SuccessBatchProcessor

    # Commits the whole batch, then dies before reporting. The fallback must
    # not revert rows that are already :processed (R11.1).
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      SuccessBatchProcessor.complete(commands)
      raise "crash after commit"
    end
  end

  setup [:create_instance, :create_accounts, :verify_on_exit!]

  # Default: assume the legacy single-cmd path. The batch-mode describe
  # block below overrides this. Doing it here keeps the existing tests
  # green even when the suite is run with `BATCH=on` (which sets
  # :batch_enabled at app boot via runtime.exs). Each test reads the
  # flag in init/1, so flipping it before start_processor/1 is enough.
  setup do
    original = Application.get_env(:double_entry_ledger, :batch_enabled)
    Application.put_env(:double_entry_ledger, :batch_enabled, false)

    on_exit(fn -> restore_env(:batch_enabled, original) end)

    :ok
  end

  setup %{instance: instance} do
    start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})
    ensure_worker_supervisor()

    {:ok, command} =
      CommandStore.create(transaction_command_attrs(instance_address: instance.address))

    %{command: command}
  end

  defp start_processor(instance_id),
    do: start_processor_with_batch(instance_id, DoubleEntryLedger.BatchProcessor)

  # Like `start_processor/1` but threads a batch_processor stub through
  # init/1. Used by the batch-mode tests below.
  defp start_processor_with_batch(instance_id, batch_processor),
    do: start_processor_with_grant(test_grant(instance_id), batch_processor)

  # The processor is handed a lease it does not acquire (acquisition is the
  # monitor's job), so the grant is created here and stashed for the test body
  # under `current_grant/0`. Stubs read it off their second argument instead:
  # they run in the task process, which has its own process dictionary.
  defp start_processor_with_grant(grant, batch_processor \\ DoubleEntryLedger.BatchProcessor) do
    ensure_worker_supervisor()

    {:ok, pid} =
      GenServer.start_link(InstanceProcessor, %{
        instance_id: grant.instance_id,
        grant: grant,
        worker: DoubleEntryLedger.MockCommandWorker,
        batch_processor: batch_processor
      })

    # Allow the mock to be called from any spawned task process
    Mox.allow(DoubleEntryLedger.MockCommandWorker, self(), fn -> pid end)

    ref = Process.monitor(pid)
    Process.put(:processor_grant, grant)
    {pid, ref}
  end

  defp current_grant, do: Process.get(:processor_grant)

  # Worker tasks now run under a Task.Supervisor; tests that start a processor
  # directly must start it too, once per test.
  defp ensure_worker_supervisor do
    case Process.whereis(DoubleEntryLedger.CommandQueue.WorkerSupervisor) do
      nil ->
        start_supervised!(
          {Task.Supervisor, name: DoubleEntryLedger.CommandQueue.WorkerSupervisor}
        )

      _pid ->
        :ok
    end
  end

  # Puts a queue row into the state a claim would leave it in, WITHOUT taking
  # the lease row lock. The lease-contention tests need the lease row untouched
  # by the sandbox connection: a claim through the sandbox takes that row lock
  # inside a savepoint, and releasing the savepoint promotes the lock to the
  # enclosing sandbox transaction, where it is held for the rest of the test
  # and no probe can ever contend for it.
  defp mark_processing(command_id, owner_id) do
    command_id
    |> CommandStore.get_by_id()
    |> Map.fetch!(:command_queue_item)
    |> Ecto.Changeset.change(status: :processing, processor_id: owner_id)
    |> Repo.update!()
  end

  # Every {:attempt, id} the stubs sent, in the order they were sent. Recursive,
  # so it lives outside the test body, and draining rather than a run of
  # `assert_receive` is the point: a selective receive scans past messages that
  # do not match, so it cannot pin an order.
  defp collect_attempts(acc \\ []) do
    receive do
      {:attempt, id} -> collect_attempts([id | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # Like `park_idle_with/3`, except the message that lands in the idle window is
  # the heartbeat's own `Process.send_after/3` rather than one the test sent.
  # Suspending does not stop timers: the completion is queued first, the timer's
  # `:renew_lease` behind it, and the `:process_next` the completion sends itself
  # goes behind both. The caller resumes.
  defp park_idle_for_timer(pid, task, wait_ms) do
    task_ref = Process.monitor(task)
    :sys.suspend(pid)
    send(task, :finish)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
    Process.sleep(wait_ms)
    :ok
  end

  # Every batch `SuccessBatchProcessor` ran, in order. Same reason as
  # `collect_attempts/1`: a run of `assert_receive` scans past what does not
  # match, so it cannot pin an order.
  defp collect_batch_runs(acc \\ []) do
    receive do
      {:batch_run_received, ids} -> collect_batch_runs([ids | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # Blocks inside the worker task until the test releases it. Kept out of test
  # bodies: `receive` in a test would be branching.
  defp blocking_worker(test_pid) do
    fn _id, _grant ->
      send(test_pid, {:worker_blocking, self()})

      receive do
        :finish -> {:error, :ignored}
      end
    end
  end

  # Drives the processor into its idle window deterministically: the task's
  # `{:processing_complete, ...}` is in the mailbox before `:renew_lease` is,
  # and the `:process_next` the completion sends itself lands behind both. A
  # selective `assert_receive` could not establish that ordering.
  defp park_idle_with(pid, task, message) do
    task_ref = Process.monitor(task)
    :sys.suspend(pid)
    send(task, :finish)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
    send(pid, message)
    :sys.resume(pid)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:double_entry_ledger, key)
  defp restore_env(key, value), do: Application.put_env(:double_entry_ledger, key, value)

  # Inserts an additional balanced :create_transaction command for
  # the given instance + accounts. Returns the command struct.
  defp insert_create_command(instance, [a1, a2 | _], amount) do
    {:ok, cmd} =
      CommandStore.create(
        transaction_command_attrs(
          instance_address: instance.address,
          source: "src",
          source_idempk: "idempk-#{System.unique_integer([:positive])}",
          payload: %TransactionData{
            status: :posted,
            entries: [
              %{account_address: a1.address, amount: amount, currency: "EUR"},
              %{account_address: a2.address, amount: amount, currency: "EUR"}
            ]
          }
        )
      )

    cmd
  end

  # Insert a :create_transaction command that IS extracted but WILL fail
  # the batch fold: negative amounts on accounts a3/a4 whose
  # `negative_limit: 0` make `compute_balance_changes/3` reject the entry,
  # producing a `{:balance_change_error, :available, _}` failure. This is
  # the same fold-failure path the real BatchProcessor persists via
  # `write_failures` (mirrors the helper in batch_processor_run_batch_test).
  defp insert_overdraft_command(instance, accounts) do
    a3 = Enum.at(accounts, 2)
    a4 = Enum.at(accounts, 3)

    {:ok, cmd} =
      CommandStore.create(
        transaction_command_attrs(
          instance_address: instance.address,
          source: "src",
          source_idempk: "idempk-overdraft-#{System.unique_integer([:positive])}",
          payload: %TransactionData{
            status: :posted,
            entries: [
              %{account_address: a3.address, amount: -100, currency: "EUR"},
              %{account_address: a4.address, amount: -100, currency: "EUR"}
            ]
          }
        )
      )

    CommandStore.get_by_id(cmd.id)
  end

  describe "successful processing" do
    test "processes command and shuts down", %{instance: instance, command: command} do
      # Mimic the real worker's side effect: mark the command as :processed.
      # Without this, the InstanceProcessor's `:process_next` loop would re-claim
      # the same command (status still :pending) and call the mock a second
      # time, producing spurious Mox.UnexpectedCallError noise in test output.
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _grant ->
        assert id == command.id

        command
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        {:ok, nil, nil}
      end)

      {_pid, ref} = start_processor(instance.id)

      # Processor finds command → task succeeds → no more commands → shuts down
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end

    test "pending_fetch_limit bounds the in-memory ID buffer", %{
      instance: instance,
      accounts: accounts
    } do
      insert_create_command(instance, accounts, 10)

      original = Application.get_env(:double_entry_ledger, :command_queue)

      Application.put_env(
        :double_entry_ledger,
        :command_queue,
        Keyword.put(original || [], :pending_fetch_limit, 1)
      )

      on_exit(fn -> restore_env(:command_queue, original) end)

      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _grant ->
        send(test_pid, {:worker_started, self()})
        assert_receive :continue, 5000

        id
        |> CommandStore.get_by_id()
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        {:ok, nil, nil}
      end)

      {pid, ref} = start_processor(instance.id)

      assert_receive {:worker_started, first_worker}, 5000
      assert %{pending_ids: []} = :sys.get_state(pid)
      send(first_worker, :continue)

      assert_receive {:worker_started, second_worker}, 5000
      send(second_worker, :continue)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end
  end

  describe "error processing" do
    test "handles worker error and shuts down", %{instance: instance, command: command} do
      # Same rationale as the success test: terminate the loop by
      # transitioning the command to a non-claimable state — here
      # :dead_letter, since the test simulates a non-recoverable worker error.
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn _id, _grant ->
        Scheduling.mark_as_dead_letter(command, "some worker error")

        {:error, :some_worker_error}
      end)

      {_pid, ref} = start_processor(instance.id)

      # Processor finds command → task returns error → no more commands → shuts down
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end
  end

  describe "task crash recovery" do
    test "does not schedule a retry after command ownership has changed", %{
      instance: instance,
      command: command
    } do
      command_id = command.id

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn ^command_id, grant ->
        {:ok, claimed} = Scheduling.claim_command_for_processing(command_id, grant)

        claimed.command_queue_item
        |> Ecto.Changeset.change(processor_id: "replacement-owner")
        |> Repo.update!()

        raise "crash after ownership changed"
      end)

      {_pid, ref} = start_processor(instance.id)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      current = Repo.get_by!(CommandQueueItem, command_id: command_id)
      assert current.status == :processing
      assert current.processor_id == "replacement-owner"
    end

    test "schedules retry when worker crashes", %{instance: instance, command: command} do
      # `stub` (not `expect`) — the InstanceProcessor's retry loop may invoke
      # the mock more than once before the command is dead-lettered, depending
      # on timing of `next_retry_after`. A 1-call `expect` would itself raise
      # `Mox.UnexpectedCallError` on a second invocation, polluting the
      # output and triggering further retry cycles before final shutdown.
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, _claimed} = Scheduling.claim_command_for_processing(id, grant)
        raise "intentional crash"
      end)

      {_pid, ref} = start_processor(instance.id)

      # Processor: find command → task crashes → :DOWN → schedule retry → no more → shutdown
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(command.id)
      assert updated.command_queue_item.status == :failed
      assert updated.command_queue_item.next_retry_after != nil
      assert [%{"message" => "Task crashed:" <> _} | _] = updated.command_queue_item.errors
    end

    test "dead-letters when max retries exceeded", %{instance: instance, command: command} do
      max_retries = Application.get_env(:double_entry_ledger, :command_queue)[:max_retries] || 5

      # Set retry_count to max before processing
      command.command_queue_item
      |> Ecto.Changeset.change(%{retry_count: max_retries})
      |> Repo.update!()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, _claimed} = Scheduling.claim_command_for_processing(id, grant)
        raise "crash after max retries"
      end)

      {_pid, ref} = start_processor(instance.id)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(command.id)
      assert updated.command_queue_item.status == :dead_letter
    end
  end

  describe "batch mode (BATCH=on)" do
    setup do
      # Register the test pid under a known name so the stub batch
      # processors (running inside spawned Tasks) can `send/2` back
      # without us having to thread a pid through.
      Process.register(self(), :batch_processor_test_observer)

      original = Application.get_env(:double_entry_ledger, :batch_enabled)
      Application.put_env(:double_entry_ledger, :batch_enabled, true)

      on_exit(fn -> restore_env(:batch_enabled, original) end)

      :ok
    end

    test "all-create batch dispatches via BatchProcessor and processes every command",
         %{instance: instance, command: existing, accounts: accounts} do
      # Start with a known-good batch: 3 :create_transaction commands.
      # The fixture-provided `existing` command also is :create_transaction
      # (and :pending) so we use it as the first batch member.
      c2 = insert_create_command(instance, accounts, 50)
      c3 = insert_create_command(instance, accounts, 75)

      expected_ids = [existing.id, c2.id, c3.id]

      {_pid, ref} = start_processor_with_batch(instance.id, SuccessBatchProcessor)

      # Wait for the batch task to receive the commands in their stable,
      # database-assigned queue order.
      assert_receive {:batch_run_received, received_ids}, 5000
      assert received_ids == expected_ids

      # GenServer should drain and shut down :normal (queue rows were
      # marked :processed by the stub).
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      # All three queue rows are :processed.
      qi_statuses =
        Repo.all(
          from(q in CommandQueueItem,
            where: q.command_id in ^expected_ids,
            select: q.status
          )
        )

      assert length(qi_statuses) == 3
      assert Enum.all?(qi_statuses, &(&1 == :processed))
    end

    test "a configured batch size of zero is clamped to one", %{
      instance: instance,
      command: command
    } do
      original = Application.get_env(:double_entry_ledger, :batch_size)
      Application.put_env(:double_entry_ledger, :batch_size, 0)

      on_exit(fn -> restore_env(:batch_size, original) end)

      {_pid, ref} = start_processor_with_batch(instance.id, SuccessBatchProcessor)

      assert_receive {:batch_run_received, [command_id]}, 5000
      assert command_id == command.id
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end

    test "selects commands in queue-position order regardless of inserted_at",
         %{instance: instance, command: existing, accounts: accounts} do
      c2 = insert_create_command(instance, accounts, 50)
      c3 = insert_create_command(instance, accounts, 75)

      from(q in CommandQueueItem, where: q.command_id == ^existing.id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), 3_600)])

      {_pid, ref} = start_processor_with_batch(instance.id, SuccessBatchProcessor)

      assert_receive {:batch_run_received, received_ids}, 5000
      assert received_ids == [existing.id, c2.id, c3.id]
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end

    test "batches the prefix before a non-batchable command and resumes batching after it",
         %{instance: instance, command: first_create, accounts: accounts} do
      second_create = insert_create_command(instance, accounts, 20)

      {:ok, account_cmd} =
        CommandStore.create(account_command_attrs(%{instance_address: instance.address}))

      final_create = insert_create_command(instance, accounts, 30)

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _grant ->
        cmd =
          Command
          |> Repo.get!(id)
          |> Repo.preload(:command_queue_item)

        cmd
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        send(:batch_processor_test_observer, {:worker_processed, id})
        {:ok, nil, nil}
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, SuccessBatchProcessor)

      first_id = first_create.id
      second_id = second_create.id
      account_id = account_cmd.id
      final_id = final_create.id

      assert_receive {:batch_run_received, [^first_id, ^second_id]}, 5000
      assert_receive {:worker_processed, ^account_id}, 5000
      assert_receive {:batch_run_received, [^final_id]}, 5000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      refute_received {:worker_processed, _}
    end

    test "drops a disappeared command ID without disrupting the following batch",
         %{instance: instance, command: first_create, accounts: accounts} do
      second_create = insert_create_command(instance, accounts, 20)

      {:ok, account_cmd} =
        CommandStore.create(account_command_attrs(%{instance_address: instance.address}))

      final_create = insert_create_command(instance, accounts, 30)

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _grant ->
        send(:batch_processor_test_observer, {:worker_processed, id})
        {:error, :unexpected_single_processing}
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, BlockingSuccessBatchProcessor)

      first_id = first_create.id
      second_id = second_create.id
      final_id = final_create.id

      assert_receive {:blocking_batch_started, first_task, [^first_id, ^second_id]}, 5000
      assert {:ok, _deleted} = Repo.delete(account_cmd)
      send(first_task, :continue)

      assert_receive {:blocking_batch_started, final_task, [^final_id]}, 5000
      send(final_task, :continue)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
      refute_received {:worker_processed, _}
    end

    test "batch task crash falls back to isolated single-command processing",
         %{instance: instance, command: existing, accounts: accounts} do
      c2 = insert_create_command(instance, accounts, 50)

      expected_ids = MapSet.new([existing.id, c2.id])
      crashing_id = existing.id
      healthy_id = c2.id

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn ^crashing_id, grant ->
        {:ok, _claimed} =
          Scheduling.claim_command_for_processing(crashing_id, grant)

        raise "deterministic command crash"
      end)

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn ^healthy_id, grant ->
        {:ok, command} = Scheduling.claim_command_for_processing(healthy_id, grant)

        command
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        send(:batch_processor_test_observer, {:worker_processed, healthy_id})
        {:ok, nil, command}
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, CrashBatchProcessor)

      # Stub processor was reached.
      assert_receive {:batch_run_received, received_ids}, 5000
      assert MapSet.new(received_ids) == expected_ids

      assert_receive {:worker_processed, ^healthy_id}, 5000

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      crashing_queue_item = Repo.get_by!(CommandQueueItem, command_id: crashing_id)
      healthy_queue_item = Repo.get_by!(CommandQueueItem, command_id: healthy_id)

      assert crashing_queue_item.status == :failed
      assert healthy_queue_item.status == :processed
      assert healthy_queue_item.errors == []
    end

    test "batch crash requeues only claims that were actually reverted",
         %{instance: instance, command: committed, accounts: accounts} do
      remaining = insert_create_command(instance, accounts, 50)
      committed_id = committed.id
      remaining_id = remaining.id

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn ^remaining_id, _grant ->
        command = CommandStore.get_by_id(remaining_id)

        command
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        {:ok, nil, command}
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, PartialCommitCrashBatchProcessor)

      assert_receive {:partial_batch_crashed, ^committed_id, [^committed_id, ^remaining_id]}, 5000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
      assert Repo.get_by!(CommandQueueItem, command_id: committed_id).status == :processed
      assert Repo.get_by!(CommandQueueItem, command_id: remaining_id).status == :processed
    end

    test "batch crash does not revert a claim now owned by another processor",
         %{instance: instance, command: stolen, accounts: accounts} do
      remaining = insert_create_command(instance, accounts, 50)
      stolen_id = stolen.id
      remaining_id = remaining.id

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn ^remaining_id, _grant ->
        command = CommandStore.get_by_id(remaining_id)

        command
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        {:ok, nil, command}
      end)

      {_pid, ref} =
        start_processor_with_batch(instance.id, OwnershipLostCrashBatchProcessor)

      assert_receive {:batch_ownership_lost, ^stolen_id, [^stolen_id, ^remaining_id]}, 5000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      current = Repo.get_by!(CommandQueueItem, command_id: stolen_id)
      assert current.status == :processing
      assert current.processor_id == "replacement-owner"
      assert Repo.get_by!(CommandQueueItem, command_id: remaining_id).status == :processed
    end

    # ── Finding 1: batch path must claim so the failure lifecycle
    #    (retry_count progression, backoff, dead-letter) matches legacy.
    #    Driven through the REAL BatchProcessor so the actual claim +
    #    write_failures run. `run_batch` itself must NOT bump retry_count
    #    (that stays asserted in batch_processor_run_batch_test); the bump
    #    must come from the InstanceProcessor claiming the batch.

    test "batch validation failure claims the command so retry_count progresses",
         %{instance: instance, command: fixture, accounts: accounts} do
      # Exclude the auto-created fixture command so the batch is exactly
      # the one failing command under test.
      fixture.command_queue_item
      |> Ecto.Changeset.change(%{status: :processed})
      |> Repo.update!()

      bad = insert_overdraft_command(instance, accounts)

      # Simulate a command that already had one prior attempt and is
      # eligible to retry now: :occ_timeout (a non-pending, re-claimable
      # state), retry_count 1, next_retry_after in the past.
      bad.command_queue_item
      |> Ecto.Changeset.change(%{
        status: :occ_timeout,
        retry_count: 1,
        next_retry_after: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Repo.update!()

      {_pid, ref} = start_processor_with_batch(instance.id, DoubleEntryLedger.BatchProcessor)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(bad.id)

      # Claiming a non-pending command bumps retry_count 1 → 2 (via
      # retry_count_by_status); the failure writer leaves it there, so the
      # row ends :failed with retry_count 2. Today the batch path never
      # claims, so retry_count stays 1 and this assertion fails.
      assert updated.command_queue_item.retry_count == 2
      assert updated.command_queue_item.status == :failed
    end

    test "batch validation failure computes backoff from the post-claim retry_count",
         %{instance: instance, command: fixture, accounts: accounts} do
      fixture.command_queue_item
      |> Ecto.Changeset.change(%{status: :processed})
      |> Repo.update!()

      base = Application.get_env(:double_entry_ledger, :command_queue)[:base_retry_delay] || 30

      bad = insert_overdraft_command(instance, accounts)

      bad.command_queue_item
      |> Ecto.Changeset.change(%{
        status: :occ_timeout,
        retry_count: 2,
        next_retry_after: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Repo.update!()

      t0 = DateTime.utc_now()
      {_pid, ref} = start_processor_with_batch(instance.id, DoubleEntryLedger.BatchProcessor)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(bad.id)

      # The claim bumps retry_count 2 → 3, so the exponential backoff must
      # be base * 2^3 (≈ base*8s), not base * 2^2 (≈ base*4s). Assert
      # next_retry_after lands beyond the midpoint of those two delays;
      # today (no claim) it is computed off retry_count 2 and falls short.
      midpoint_delay = div(base * 4 + base * 8, 2)
      threshold = DateTime.add(t0, midpoint_delay, :second)

      assert DateTime.compare(updated.command_queue_item.next_retry_after, threshold) == :gt
      assert updated.command_queue_item.retry_count == 3
    end

    test "batch validation failure dead-letters when the claim tips retry_count over the ceiling",
         %{instance: instance, command: fixture, accounts: accounts} do
      fixture.command_queue_item
      |> Ecto.Changeset.change(%{status: :processed})
      |> Repo.update!()

      max_retries = Application.get_env(:double_entry_ledger, :command_queue)[:max_retries] || 5

      bad = insert_overdraft_command(instance, accounts)

      # One short of the ceiling: today the batch path never claims, so
      # retry_count stays at (max - 1), the failure stays :failed, and the
      # command can never dead-letter. With the claim, retry_count is
      # bumped to max and the failure writer dead-letters it.
      bad.command_queue_item
      |> Ecto.Changeset.change(%{
        status: :occ_timeout,
        retry_count: max_retries - 1,
        next_retry_after: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Repo.update!()

      {_pid, ref} = start_processor_with_batch(instance.id, DoubleEntryLedger.BatchProcessor)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(bad.id)
      assert updated.command_queue_item.status == :dead_letter
    end

    test "already-:failed command that fails again is handled cleanly (no writer crash)",
         %{instance: instance, command: fixture, accounts: accounts} do
      # Regression for a latent crash: when a batched command is already
      # :failed and fails again, the failure writer's compute_failure_outcome
      # sees no :status change (:failed → :failed) and today raises a
      # CaseClauseError, crashing the whole batch write. Claiming first moves
      # the command to :processing, so the failure always transitions cleanly.
      fixture.command_queue_item
      |> Ecto.Changeset.change(%{status: :processed})
      |> Repo.update!()

      bad = insert_overdraft_command(instance, accounts)

      bad.command_queue_item
      |> Ecto.Changeset.change(%{
        status: :failed,
        retry_count: 1,
        next_retry_after: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Repo.update!()

      {_pid, ref} = start_processor_with_batch(instance.id, DoubleEntryLedger.BatchProcessor)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(bad.id)

      # Clean handling: claimed (retry_count 1 → 2), then written :failed by
      # the failure writer with the REAL fold reason. Today the writer
      # crashes, the batch task dies, and the :DOWN handler records a
      # "Task crashed" error with retry_count left at 1.
      assert updated.command_queue_item.status == :failed
      assert updated.command_queue_item.retry_count == 2

      refute Enum.any?(updated.command_queue_item.errors, fn err ->
               String.contains?(err["message"] || "", "crashed")
             end)
    end

    # ── Finding 2: an unexpected (non-stale) DB error from the batched
    #    write must fall back to per-command processing for that batch,
    #    not leave the commands stuck in the queue.

    test "batch DB error falls back to per-command processing",
         %{instance: instance, command: fixture, accounts: accounts} do
      fixture.command_queue_item
      |> Ecto.Changeset.change(%{status: :processed})
      |> Repo.update!()

      c1 = insert_create_command(instance, accounts, 30)
      c2 = insert_create_command(instance, accounts, 40)
      batch_ids = MapSet.new([c1.id, c2.id])

      # The fallback runs each command through the single-cmd worker path.
      # Report which id was handled and mark it processed so the queue
      # drains and the GenServer shuts down.
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _grant ->
        Command
        |> Repo.get!(id)
        |> Repo.preload(:command_queue_item)
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        send(:batch_processor_test_observer, {:worker_processed, id})
        {:ok, nil, nil}
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, DbErrorBatchProcessor)

      # The batch stub is reached and returns a non-stale DB error.
      assert_receive {:batch_run_received, received}, 5000
      assert MapSet.new(received) == batch_ids

      # Finding 2: each command must then be processed via the single-cmd
      # path. Today the caller only logs the error, so the worker is never
      # invoked and both of these time out.
      assert_receive {:worker_processed, id_a}, 5000
      assert_receive {:worker_processed, id_b}, 5000
      assert MapSet.new([id_a, id_b]) == batch_ids

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end

    test "live-toggling :batch_enabled off is honored by a running processor (no restart)",
         %{instance: instance, command: fixture, accounts: accounts} do
      # Exclude the fixture command; drive exactly two batchable commands.
      fixture.command_queue_item
      |> Ecto.Changeset.change(%{status: :processed})
      |> Repo.update!()

      # batch_size 1 so each :process_next round handles a single command,
      # giving a round boundary at which the flipped flag can take effect.
      original_size = Application.get_env(:double_entry_ledger, :batch_size)
      Application.put_env(:double_entry_ledger, :batch_size, 1)

      on_exit(fn -> restore_env(:batch_size, original_size) end)

      insert_create_command(instance, accounts, 30)
      insert_create_command(instance, accounts, 40)

      # Legacy single-cmd path for the second round (after the flag flips).
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _grant ->
        Command
        |> Repo.get!(id)
        |> Repo.preload(:command_queue_item)
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        send(:batch_processor_test_observer, {:worker_processed, id})
        {:ok, nil, nil}
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, ToggleOffBatchProcessor)

      # Round 1: batch on → one command via the batch processor, which flips
      # the flag off. Round 2: batch off → one command via the worker. Today
      # the flag is cached at init, so round 2 still batches and the worker
      # is never reached.
      assert_receive {:batch_run_received, batched}, 5000
      assert length(batched) == 1

      assert_receive {:worker_processed, _id}, 5000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end
  end

  describe "lease lifecycle" do
    test "passes its grant to the worker", %{instance: instance} do
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        send(test_pid, {:worker_called_with, grant})
        {:ok, cmd} = Scheduling.claim_command_for_processing(id, grant)
        Repo.update!(Scheduling.build_mark_as_processed(cmd))
        {:ok, :done, :done}
      end)

      {_pid, ref} = start_processor(instance.id)
      grant = current_grant()

      assert_receive {:worker_called_with, ^grant}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    end

    test "releases the lease on drain", %{instance: instance} do
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, cmd} = Scheduling.claim_command_for_processing(id, grant)
        Repo.update!(Scheduling.build_mark_as_processed(cmd))
        {:ok, :done, :done}
      end)

      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      {_pid, ref} = start_processor(instance.id)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert lease_row(instance.id).released_at
      assert_receive {:telemetry_event, ^released, _, _, %{reason: :drained}}
    end

    test "heartbeat with a task in flight makes no database call", %{instance: instance} do
      put_queue_config(lease_ttl: 3)

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, blocking_worker(self()))

      renewed = attach_telemetry([:double_entry_ledger, :lease, :renewed])
      {pid, _ref} = start_processor(instance.id)
      assert_receive {:worker_blocking, _task}, 2_000

      queries = attach_telemetry([:double_entry_ledger, :repo, :query])
      send(pid, :renew_lease)
      send(pid, :renew_lease)
      send(pid, :renew_lease)

      refute_receive {:telemetry_event, ^renewed, _, _, _}, 500

      # The named property is "no database call", not "no event": a renewal
      # under a locked row would return :busy and emit nothing while still
      # making a round trip on every heartbeat.
      assert lease_update_count(write_sequence(queries)) == 0
      assert Process.alive?(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    test "heartbeat while idle renews and emits", %{instance: instance} do
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, blocking_worker(self()))

      {pid, _ref} = start_processor(instance.id)
      grant = current_grant()
      assert_receive {:worker_blocking, task}, 2_000

      renewed = attach_telemetry([:double_entry_ledger, :lease, :renewed])
      park_idle_with(pid, task, :renew_lease)

      assert_receive {:telemetry_event, ^renewed, _, _, %{owner_id: owner}}, 2_000
      assert owner == grant.owner_id
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    # The heartbeat has to arrive on its own timer, not only when a test sends
    # `:renew_lease`. Suspending the processor while its task is blocked lets
    # the completion and then the TIMER's own message queue up in that order, so
    # the renewal is handled in the idle window between them.
    test "the heartbeat timer renews the lease unprompted", %{instance: instance} do
      put_queue_config(lease_ttl: 3)

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, blocking_worker(self()))

      {pid, _ref} = start_processor(instance.id)
      assert_receive {:worker_blocking, task}, 2_000

      park_idle_for_timer(pid, task, 1_500)
      renewed = attach_telemetry([:double_entry_ledger, :lease, :renewed])
      :sys.resume(pid)

      assert_receive {:telemetry_event, ^renewed, _, _, _}, 2_000
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    test "heartbeat :lost while idle stops without release", %{instance: instance} do
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, blocking_worker(self()))

      {pid, ref} = start_processor(instance.id)
      assert_receive {:worker_blocking, task}, 2_000

      expire_lease(instance.id)
      _successor = test_grant(instance.id)
      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])
      park_idle_with(pid, task, :renew_lease)

      assert_receive {:telemetry_event, ^lost, _, _, %{source: :renewal}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      # No `refute ... released_at` here: the successor holds the row, so a
      # release on the stale grant matches zero rows and could not show up.
    end

    test "a {:error, :lease_lost} task result stops the processor", %{instance: instance} do
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn _id, _grant -> {:error, :lease_lost} end)

      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])
      {_pid, ref} = start_processor(instance.id)

      assert_receive {:telemetry_event, ^lost, _, _, %{source: :transaction}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      # The worker reported loss without a takeover, so the row still matches
      # the grant: a `terminate/2` that released would be visible here.
      refute lease_row(instance.id).released_at
    end

    test "a {:error, :lease_busy} task result reverts the row and retries", %{
      instance: instance,
      command: command
    } do
      put_queue_config(lease_lock_timeout_ms: 50)
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        {:error, :lease_busy}
      end)
      |> expect(:process_command_with_id, fn id, grant ->
        send(test_pid, :second_attempt)
        {:ok, cmd} = Scheduling.claim_command_for_processing(id, grant)
        Repo.update!(Scheduling.build_mark_as_processed(cmd))
        {:ok, :done, :done}
      end)

      {_pid, ref} = start_processor(instance.id)

      assert_receive :second_attempt, 3_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processed
    end

    # The lease row has to live outside the sandbox for a second connection to
    # be able to hold it, and this processor must never take that row lock
    # through the sandbox before the probe does — hence `mark_processing/2` in
    # place of a real claim on the first attempt.
    # Dispatch has already popped the head, so the buffer holds the LATER ids.
    # Requeueing the reverted, lower-position id at the head is what keeps the
    # queue first-in-first-out; refilling from the database only after the
    # buffer drains would put the reverted command last, which on a ledger
    # where a create precedes its update is a correctness difference.
    test "a busy revert requeues the reverted command ahead of the buffered ones", %{
      instance: instance,
      command: first,
      accounts: accounts
    } do
      put_queue_config(lease_lock_timeout_ms: 50)
      second = insert_create_command(instance, accounts, 10)
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        send(test_pid, {:attempt, id})
        {:error, :lease_busy}
      end)
      |> stub(:process_command_with_id, fn id, grant ->
        send(test_pid, {:attempt, id})
        {:ok, cmd} = Scheduling.claim_command_for_processing(id, grant)
        Repo.update!(Scheduling.build_mark_as_processed(cmd))
        {:ok, :done, :done}
      end)

      {_pid, ref} = start_processor(instance.id)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert collect_attempts() == [first.id, first.id, second.id]
    end

    # Pinned by POSITION, the way `lease_fence_test.exs` pins the other fenced
    # writes: `lock!/3` and `refresh_locked!/3` issue the identical statement,
    # so only the order and count of lease-row writes can show the wrapper is
    # there. Four: the claim's pair, then the cleanup's pair.
    test "the crash retry write is wrapped in the lease fence", %{
      instance: instance,
      accounts: accounts
    } do
      test_pid = self()
      # A second command, so the cleanup is followed by another dispatch rather
      # than by the drain, whose release would be a fifth lease write. The
      # blocking stub then stops the sequence before that dispatch touches the
      # database.
      insert_create_command(instance, accounts, 10)

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        send(test_pid, :claimed)
        raise "crash under the lease"
      end)
      |> stub(:process_command_with_id, blocking_worker(test_pid))

      grant = test_grant(instance.id)
      queries = attach_telemetry([:double_entry_ledger, :repo, :query])
      {pid, _ref} = start_processor_with_grant(grant)

      assert_receive :claimed, 2_000
      assert_receive {:worker_blocking, _task}, 2_000
      sequence = write_sequence(queries)

      assert lease_update_count(sequence) == 4
      assert List.first(sequence) == :lease
      assert List.last(sequence) == :lease

      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    test "the busy revert write is wrapped in the lease fence", %{instance: instance} do
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        send(test_pid, :busy_reported)
        {:error, :lease_busy}
      end)
      |> stub(:process_command_with_id, blocking_worker(test_pid))

      grant = test_grant(instance.id)
      queries = attach_telemetry([:double_entry_ledger, :repo, :query])
      {pid, _ref} = start_processor_with_grant(grant)

      assert_receive :busy_reported, 2_000
      # The revert requeues the command, so the next dispatch is the blocking
      # stub and the sequence stops at the cleanup's closing refresh.
      assert_receive {:worker_blocking, _task}, 2_000
      sequence = write_sequence(queries)

      assert lease_update_count(sequence) == 4
      assert List.first(sequence) == :lease
      assert List.last(sequence) == :lease

      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    test "a {:error, :lease_busy} whose revert is itself busy is retried, not abandoned" do
      put_queue_config(lease_lock_timeout_ms: 150)
      probe = probe_connection()
      grant = committed_lease(probe, "busy-owner:#{Ecto.UUID.generate()}", 1)
      {:ok, command} = create_command_on(grant.instance_id)
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn id, worker_grant ->
        mark_processing(id, worker_grant.owner_id)
        {:error, :lease_busy}
      end)
      |> expect(:process_command_with_id, fn id, worker_grant ->
        send(test_pid, :second_attempt)
        {:ok, cmd} = Scheduling.claim_command_for_processing(id, worker_grant)
        Repo.update!(Scheduling.build_mark_as_processed(cmd))
        {:ok, :done, :done}
      end)

      hold_lock_on_probe(probe, grant)
      {pid, ref} = start_processor_with_grant(grant)

      # Cleanup is blocked by the probe: pending_cleanup is set and no work is
      # dispatched, not even for a `:process_next` still in flight from before.
      Process.sleep(600)
      assert %{pending_cleanup: {:revert, _, :resume}} = :sys.get_state(pid)
      send(pid, :process_next)
      Process.sleep(200)
      refute_received :second_attempt

      rollback_probe(probe)

      assert_receive :second_attempt, 3_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processed
    end

    test "a {:error, :lease_busy} whose revert finds the lease taken stops the processor", %{
      instance: instance,
      command: command
    } do
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        expire_lease(grant.instance_id)
        _successor = test_grant(grant.instance_id)
        send(test_pid, :busy_reported)
        {:error, :lease_busy}
      end)

      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])
      {_pid, ref} = start_processor(instance.id)

      assert_receive :busy_reported, 2_000
      assert_receive {:telemetry_event, ^lost, _, _, %{source: :transaction}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :failed
    end

    test "a task that commits and dies before reporting is not rescheduled", %{
      instance: instance,
      command: command
    } do
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, cmd} = Scheduling.claim_command_for_processing(id, grant)
        Repo.update!(Scheduling.build_mark_as_processed(cmd))
        send(test_pid, :committed)
        exit(:killed_after_commit)
      end)

      {_pid, ref} = start_processor(instance.id)

      assert_receive :committed, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processed
    end

    test "a task crash after a takeover reschedules nothing and stops the processor", %{
      instance: instance
    } do
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        expire_lease(grant.instance_id)
        _successor = test_grant(grant.instance_id)
        raise "boom"
      end)

      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])
      {_pid, ref} = start_processor(instance.id)

      assert_receive {:telemetry_event, ^lost, _, _, %{source: :transaction}}, 3_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 3_000
    end

    test "shutdown with a task in flight kills it, then releases; the row stays :processing", %{
      instance: instance,
      command: command
    } do
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        send(test_pid, :claimed)
        Process.sleep(:infinity)
      end)

      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      {pid, ref} = start_processor(instance.id)
      assert_receive :claimed, 2_000

      # start_link linked the processor to this test process; an exit signal it
      # does not trap would come straight back down the link and kill the test.
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 7_000
      assert_receive {:telemetry_event, ^released, _, _, %{reason: :shutdown}}, 1_000
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processing
    end

    # A processor holding a cleanup it could not land is alive, idle, and has no
    # task to kill, which is the state `terminate/2`'s last clause is for. The
    # probe is rolled back only AFTER the cleanup has timed out, so the release
    # finds the row free; rolling it back earlier would let the cleanup succeed.
    test "shutdown with nothing in flight releases with :shutdown" do
      put_queue_config(lease_lock_timeout_ms: 1_000)
      probe = probe_connection()
      grant = committed_lease(probe, "idle-shutdown-owner:#{Ecto.UUID.generate()}", 1)
      {:ok, _command} = create_command_on(grant.instance_id)
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, worker_grant ->
        mark_processing(id, worker_grant.owner_id)
        send(test_pid, :busy_reported)
        {:error, :lease_busy}
      end)

      hold_lock_on_probe(probe, grant)
      released = attach_telemetry([:double_entry_ledger, :lease, :released])
      {pid, ref} = start_processor_with_grant(grant)

      assert_receive :busy_reported, 2_000
      # The cleanup blocks for the whole lock timeout, then parks.
      Process.sleep(1_300)

      assert %{pending_cleanup: {:revert, _, :resume}, in_flight: nil} = :sys.get_state(pid)

      rollback_probe(probe)
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 5_000
      assert_receive {:telemetry_event, ^released, _, _, %{reason: :shutdown}}, 1_000
    end

    test "worker tasks run under WorkerSupervisor and die with it", %{instance: instance} do
      test_pid = self()

      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, grant ->
        {:ok, _} = Scheduling.claim_command_for_processing(id, grant)
        send(test_pid, :in_task)
        Process.sleep(:infinity)
      end)

      {pid, _ref} = start_processor(instance.id)
      assert_receive :in_task, 2_000

      [task] = Task.Supervisor.children(DoubleEntryLedger.CommandQueue.WorkerSupervisor)
      task_ref = Process.monitor(task)

      stop_supervised!(DoubleEntryLedger.CommandQueue.WorkerSupervisor)

      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end

  describe "batch lease outcomes" do
    setup do
      original = Application.get_env(:double_entry_ledger, :batch_enabled)
      Application.put_env(:double_entry_ledger, :batch_enabled, true)
      on_exit(fn -> restore_env(:batch_enabled, original) end)

      :persistent_term.put(
        {DoubleEntryLedger.CommandQueue.InstanceProcessorTest, :busy_done},
        false
      )

      :ok
    end

    test "batch {:error, :lease_lost} stops without fallback and without release", ctx do
      insert_create_command(ctx.instance, ctx.accounts, 10)
      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])

      {_pid, ref} = start_processor_with_batch(ctx.instance.id, LeaseLostBatchProcessor)

      assert_receive {:telemetry_event, ^lost, _, _, %{source: :transaction}}, 3_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 3_000
      refute lease_row(ctx.instance.id).released_at

      assert Repo.aggregate(from(q in CommandQueueItem, where: q.status == :processing), :count) >=
               1
    end

    # The rescue on `claim_and_start_batch/2`: the claim itself raises inside the
    # processor, before any task is started, so this is the only path that
    # reports `source: :claim`.
    test "a batch claim that finds the lease taken stops the processor", ctx do
      insert_create_command(ctx.instance, ctx.accounts, 10)
      grant = test_grant(ctx.instance.id)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      lost = attach_telemetry([:double_entry_ledger, :lease, :lost])
      {_pid, ref} = start_processor_with_grant(grant, SilentSuccessBatchProcessor)

      assert_receive {:telemetry_event, ^lost, _, _, %{source: :claim}}, 3_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 3_000
    end

    # The BusyError half of the same rescue. The batch claim is the first
    # statement that touches the lease row through the sandbox, so a
    # `committed_lease/3` row with the probe already holding it is the only way
    # to reach this clause: any claim made through the sandbox first would take
    # that row lock inside a savepoint, and releasing the savepoint promotes it
    # to the enclosing sandbox transaction, where it is held for the rest of the
    # test and nothing can contend.
    #
    # `batch_size: 1` is what makes the requeue visible. Dispatch has already
    # moved the ids beyond the window into `pending_ids`, so without the requeue
    # the rejected batch would go to the back and run second.
    test "a batch claim that finds the lease row locked requeues it and retries by timer" do
      put_queue_config(lease_lock_timeout_ms: 150)
      original_size = Application.get_env(:double_entry_ledger, :batch_size)
      Application.put_env(:double_entry_ledger, :batch_size, 1)
      on_exit(fn -> restore_env(:batch_size, original_size) end)
      Process.register(self(), :batch_processor_test_observer)

      probe = probe_connection()
      grant = committed_lease(probe, "batch-busy-owner:#{Ecto.UUID.generate()}", 1)
      {:ok, first} = create_command_on(grant.instance_id)
      {:ok, second} = create_command_on(grant.instance_id)
      first_id = first.id
      second_id = second.id

      hold_lock_on_probe(probe, grant)
      {pid, ref} = start_processor_with_grant(grant, SuccessBatchProcessor)

      # Several claim attempts have timed out on the probe's lock by now. The
      # batch is back at the head of the buffer and nothing has run.
      Process.sleep(600)

      assert %{pending_ids: [^first_id, ^second_id], in_flight: nil} = :sys.get_state(pid)

      refute_received {:batch_run_received, _}

      rollback_probe(probe)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert collect_batch_runs() == [[first_id], [second_id]]
    end

    test "a batch that commits then crashes before reporting is not reverted", ctx do
      insert_create_command(ctx.instance, ctx.accounts, 10)

      {_pid, ref} = start_processor_with_batch(ctx.instance.id, CommitThenCrashBatchProcessor)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert Repo.aggregate(from(q in CommandQueueItem, where: q.status == :pending), :count) == 0

      assert Repo.aggregate(from(q in CommandQueueItem, where: q.status == :processed), :count) >=
               2
    end

    test "batch {:error, :lease_busy} reverts to pending and re-batches", ctx do
      put_queue_config(lease_lock_timeout_ms: 50)
      insert_create_command(ctx.instance, ctx.accounts, 10)

      {_pid, ref} = start_processor_with_batch(ctx.instance.id, LeaseBusyOnceBatchProcessor)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000

      assert Repo.aggregate(from(q in CommandQueueItem, where: q.status == :processed), :count) >=
               1
    end
  end
end
