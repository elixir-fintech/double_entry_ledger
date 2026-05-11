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

  defmodule CrashBatchProcessor do
    # Always raises — exercises the InstanceProcessor batch :DOWN handler.
    def run_batch(commands, _repo \\ DoubleEntryLedger.Repo) do
      send(:batch_processor_test_observer, {:batch_run_received, Enum.map(commands, & &1.id)})
      raise "batch crash boom"
    end
  end

  defmodule UnreachableBatchProcessor do
    # A stub used by the mixed-batch fall-back test. Must never be
    # called; raises if it is.
    def run_batch(_commands, _repo \\ DoubleEntryLedger.Repo) do
      raise "should not be reached: mixed batch must fall back to legacy path"
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

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:double_entry_ledger, :batch_enabled)
        val -> Application.put_env(:double_entry_ledger, :batch_enabled, val)
      end
    end)

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

    # Some batch tests still go through the legacy worker path (mixed
    # batch fall-back). Allow the mock for those.
    Mox.allow(DoubleEntryLedger.MockCommandWorker, self(), fn -> pid end)

    ref = Process.monitor(pid)
    {pid, ref}
  end

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

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:double_entry_ledger, :batch_enabled)
          val -> Application.put_env(:double_entry_ledger, :batch_enabled, val)
        end
      end)

      :ok
    end

    test "all-create batch dispatches via BatchProcessor and processes every command",
         %{instance: instance, command: existing, accounts: accounts} do
      # Start with a known-good batch: 3 :create_transaction commands.
      # The fixture-provided `existing` command also is :create_transaction
      # (and :pending) so we use it as the first batch member.
      c2 = insert_create_command(instance, accounts, 50)
      c3 = insert_create_command(instance, accounts, 75)

      expected_ids = MapSet.new([existing.id, c2.id, c3.id])

      {_pid, ref} = start_processor_with_batch(instance.id, SuccessBatchProcessor)

      # Wait for the batch task to receive the commands. Order is
      # claim-order (oldest inserted first), but for this assertion
      # we only need the set of ids the stub saw.
      assert_receive {:batch_run_received, received_ids}, 5000
      assert MapSet.new(received_ids) == expected_ids
      assert length(received_ids) == 3

      # GenServer should drain and shut down :normal (queue rows were
      # marked :processed by the stub).
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      # All three queue rows are :processed.
      qi_statuses =
        Repo.all(
          from(q in CommandQueueItem,
            where: q.command_id in ^MapSet.to_list(expected_ids),
            select: q.status
          )
        )

      assert length(qi_statuses) == 3
      assert Enum.all?(qi_statuses, &(&1 == :processed))
    end

    test "mixed batch (create + update) falls back to legacy single-cmd path; no batch run dispatched",
         %{instance: instance, command: create_cmd} do
      # Insert an :update_transaction command alongside the existing
      # :create_transaction. With batch_enabled and a mixed action set,
      # the InstanceProcessor must fall back to the legacy per-cmd path
      # for at least one round (no batch dispatch this round).
      {:ok, update_cmd} =
        new_update_transaction_command(
          "src",
          "src-update-idempk-#{System.unique_integer([:positive])}",
          instance.address,
          :posted,
          []
        )

      # Legacy worker path: mark each command processed when invoked,
      # so the GenServer drains and shuts down naturally.
      DoubleEntryLedger.MockCommandWorker
      |> stub(:process_command_with_id, fn id, _processor_name ->
        cmd =
          Command
          |> Repo.get!(id)
          |> Repo.preload(:command_queue_item)

        cmd
        |> Scheduling.build_mark_as_processed()
        |> Repo.update!()

        {:ok, nil, nil}
      end)

      # Stub batch processor that should NEVER be called in the mixed
      # round (we still pass it so init/1 has something to store).
      {_pid, ref} = start_processor_with_batch(instance.id, UnreachableBatchProcessor)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      # Both commands ended up :processed via the legacy path.
      [cqi_create, cqi_update] =
        Repo.all(
          from(q in CommandQueueItem,
            where: q.command_id in ^[create_cmd.id, update_cmd.id],
            order_by: q.command_id,
            select: q
          )
        )
        |> Enum.sort_by(& &1.command_id)

      assert cqi_create.status == :processed
      assert cqi_update.status == :processed

      # Sanity: no batch dispatch message arrived.
      refute_received {:batch_run_received, _}
    end

    test "batch task crash schedules retry for every command in the batch and processor stays alive",
         %{instance: instance, command: existing, accounts: accounts} do
      c2 = insert_create_command(instance, accounts, 50)

      expected_ids = MapSet.new([existing.id, c2.id])

      # Both pre-set to max retries so that after crash they will be
      # dead-lettered and the GenServer can drain → shutdown :normal.
      max_retries = Application.get_env(:double_entry_ledger, :command_queue)[:max_retries] || 5

      Enum.each([existing, c2], fn cmd ->
        cmd.command_queue_item
        |> Ecto.Changeset.change(%{retry_count: max_retries})
        |> Repo.update!()
      end)

      {_pid, ref} = start_processor_with_batch(instance.id, CrashBatchProcessor)

      # Stub processor was reached.
      assert_receive {:batch_run_received, received_ids}, 5000
      assert MapSet.new(received_ids) == expected_ids

      # Processor must NOT crash — it should drain to :normal after
      # marking every batch member's queue row.
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      # Each batch member should now be :dead_letter (max retries had
      # already been hit, so the crash scheduling tipped them over).
      [qi_a, qi_b] =
        Repo.all(
          from(q in CommandQueueItem,
            where: q.command_id in ^MapSet.to_list(expected_ids),
            select: q
          )
        )
        |> Enum.sort_by(& &1.command_id)

      assert qi_a.status == :dead_letter
      assert qi_b.status == :dead_letter

      # And the error trail shows the batch_crashed reason.
      assert Enum.any?(qi_a.errors, fn err ->
               String.contains?(err["message"] || "", "batch_crashed")
             end)
    end
  end
end
