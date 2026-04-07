defmodule DoubleEntryLedger.CommandQueue.InstanceProcessorTest do
  @moduledoc """
  Tests for the InstanceProcessor GenServer, focusing on task crash recovery.
  """
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures

  alias DoubleEntryLedger.CommandQueue.{InstanceProcessor, Scheduling}
  alias DoubleEntryLedger.Stores.CommandStore

  # A thin GenServer that reuses InstanceProcessor's handle_info callbacks
  # but ignores :process_next to prevent auto-processing/shutdown in tests.
  defmodule TestProcessor do
    use GenServer

    alias DoubleEntryLedger.CommandQueue.InstanceProcessor

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(:process_next, state), do: {:noreply, state}
    def handle_info(msg, state), do: InstanceProcessor.handle_info(msg, state)
  end

  describe "handle_info :DOWN" do
    setup [:create_instance, :create_accounts]

    setup %{instance: instance} do
      start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

      {:ok, pid} =
        TestProcessor.start_link(%{
          instance_id: instance.id,
          processing: false,
          current_command_id: nil,
          task_ref: nil
        })

      %{processor: pid}
    end

    test "schedules retry and resets state when task crashes", %{
      instance: instance,
      processor: pid
    } do
      {:ok, command} =
        CommandStore.create(transaction_event_attrs(instance_address: instance.address))

      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, "test")
      assert claimed.command_queue_item.status == :processing

      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | processing: true, current_command_id: claimed.id, task_ref: ref}
      end)

      send(pid, {:DOWN, ref, :process, self(), {:error, :something_crashed}})

      # Use :sys.get_state to synchronize — it waits for all prior messages to be processed
      state = :sys.get_state(pid)
      assert state.processing == false
      assert state.current_command_id == nil
      assert state.task_ref == nil

      updated = CommandStore.get_by_id(claimed.id)
      assert updated.command_queue_item.status == :failed
      assert updated.command_queue_item.next_retry_after != nil
      assert [%{"message" => "Task crashed:" <> _} | _] = updated.command_queue_item.errors
    end

    test "dead-letters command when max retries exceeded", %{
      instance: instance,
      processor: pid
    } do
      {:ok, command} =
        CommandStore.create(transaction_event_attrs(instance_address: instance.address))

      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, "test")
      max_retries = Application.get_env(:double_entry_ledger, :command_queue)[:max_retries] || 5

      claimed.command_queue_item
      |> Ecto.Changeset.change(%{retry_count: max_retries})
      |> Repo.update!()

      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | processing: true, current_command_id: claimed.id, task_ref: ref}
      end)

      send(pid, {:DOWN, ref, :process, self(), {:error, :crashed_again}})

      _state = :sys.get_state(pid)

      updated = CommandStore.get_by_id(claimed.id)
      assert updated.command_queue_item.status == :dead_letter
    end

    test "ignores :DOWN with non-matching ref", %{processor: pid} do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | processing: true,
            current_command_id: Ecto.UUID.generate(),
            task_ref: make_ref()
        }
      end)

      # Send :DOWN with a different ref
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})

      # State should be unchanged — the :DOWN was for a different monitor
      state = :sys.get_state(pid)
      assert state.processing == true
    end
  end

  describe "handle_info :processing_complete" do
    setup [:create_instance]

    setup %{instance: instance} do
      start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

      {:ok, pid} =
        TestProcessor.start_link(%{
          instance_id: instance.id,
          processing: false,
          current_command_id: nil,
          task_ref: nil
        })

      %{processor: pid}
    end

    test "resets state on success", %{processor: pid} do
      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | processing: true, current_command_id: Ecto.UUID.generate(), task_ref: ref}
      end)

      send(pid, {:processing_complete, "cmd_id", {:ok, nil, nil}})

      state = :sys.get_state(pid)
      assert state.processing == false
      assert state.current_command_id == nil
      assert state.task_ref == nil
    end

    test "resets state on error", %{processor: pid} do
      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | processing: true, current_command_id: Ecto.UUID.generate(), task_ref: ref}
      end)

      send(pid, {:processing_complete, "cmd_id", {:error, :some_reason}})

      state = :sys.get_state(pid)
      assert state.processing == false
      assert state.current_command_id == nil
      assert state.task_ref == nil
    end
  end

  describe "monitor integration" do
    test "Process.monitor delivers :DOWN when task crashes" do
      # Verify the fundamental mechanism: Task.start + Process.monitor → :DOWN
      test_pid = self()

      {:ok, task_pid} =
        Task.start(fn ->
          send(test_pid, :task_started)
          raise "intentional crash"
        end)

      ref = Process.monitor(task_pid)
      assert_receive :task_started, 1000
      assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 1000
    end
  end
end
