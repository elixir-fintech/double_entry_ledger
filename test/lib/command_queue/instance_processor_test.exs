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

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Command.TransactionData
  alias DoubleEntryLedger.CommandQueue.{InstanceProcessor, Scheduling}
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.{CommandQueueItem, Repo}

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

    {:ok, command} =
      CommandStore.create(transaction_command_attrs(instance_address: instance.address))

    %{command: command}
  end

  defp start_processor(instance_id) do
    {:ok, pid} =
      GenServer.start_link(
        InstanceProcessor,
        %{
          instance_id: instance_id,
          worker: DoubleEntryLedger.MockCommandWorker,
          batch_processor: DoubleEntryLedger.BatchProcessor
        }
      )

    # Allow the mock to be called from any spawned task process
    Mox.allow(DoubleEntryLedger.MockCommandWorker, self(), fn -> pid end)

    ref = Process.monitor(pid)
    {pid, ref}
  end

  # Like `start_processor/1` but threads a batch_processor stub through
  # init/1. Used by the batch-mode tests below.
  defp start_processor_with_batch(instance_id, batch_processor) do
    {:ok, pid} =
      GenServer.start_link(
        InstanceProcessor,
        %{
          instance_id: instance_id,
          worker: DoubleEntryLedger.MockCommandWorker,
          batch_processor: batch_processor
        }
      )

    # Some batch tests include non-batchable commands that still use the
    # legacy worker path. Allow the mock for those.
    Mox.allow(DoubleEntryLedger.MockCommandWorker, self(), fn -> pid end)

    ref = Process.monitor(pid)
    {pid, ref}
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
      |> stub(:process_command_with_id, fn id, _processor_name ->
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
      |> stub(:process_command_with_id, fn id, _processor_name ->
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
      |> stub(:process_command_with_id, fn _id, _processor_name ->
        Scheduling.mark_as_dead_letter(command, "some worker error")

        {:error, :some_worker_error}
      end)

      {_pid, ref} = start_processor(instance.id)

      # Processor finds command → task returns error → no more commands → shuts down
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end
  end

  describe "task crash recovery" do
    test "schedules retry when worker crashes", %{instance: instance, command: command} do
      # `stub` (not `expect`) — the InstanceProcessor's retry loop may invoke
      # the mock more than once before the command is dead-lettered, depending
      # on timing of `next_retry_after`. A 1-call `expect` would itself raise
      # `Mox.UnexpectedCallError` on a second invocation, polluting the
      # output and triggering further retry cycles before final shutdown.
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn _id, _processor_name ->
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
      |> stub(:process_command_with_id, fn _id, _processor_name ->
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
      |> stub(:process_command_with_id, fn id, _processor_name ->
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
      |> stub(:process_command_with_id, fn id, _processor_name ->
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
      |> expect(:process_command_with_id, fn ^crashing_id, _processor_name ->
        raise "deterministic command crash"
      end)

      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn ^healthy_id, _processor_name ->
        command = CommandStore.get_by_id(healthy_id)

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
      |> expect(:process_command_with_id, fn ^remaining_id, _processor_name ->
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
      |> stub(:process_command_with_id, fn id, _processor_name ->
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
      |> stub(:process_command_with_id, fn id, _processor_name ->
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
end
