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

  alias DoubleEntryLedger.CommandQueue.InstanceProcessor
  alias DoubleEntryLedger.Stores.CommandStore

  setup [:create_instance, :create_accounts, :verify_on_exit!]

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
        %{instance_id: instance_id, worker: DoubleEntryLedger.MockCommandWorker}
      )

    # Allow the mock to be called from any spawned task process
    Mox.allow(DoubleEntryLedger.MockCommandWorker, self(), fn -> pid end)

    ref = Process.monitor(pid)
    {pid, ref}
  end

  describe "successful processing" do
    test "processes command and shuts down", %{instance: instance, command: command} do
      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn id, _processor_name ->
        assert id == command.id
        {:ok, nil, nil}
      end)

      {_pid, ref} = start_processor(instance.id)

      # Processor finds command → task succeeds → no more commands → shuts down
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end
  end

  describe "error processing" do
    test "handles worker error and shuts down", %{instance: instance} do
      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn _id, _processor_name ->
        {:error, :some_worker_error}
      end)

      {_pid, ref} = start_processor(instance.id)

      # Processor finds command → task returns error → no more commands → shuts down
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    end
  end

  describe "task crash recovery" do
    test "schedules retry when worker crashes", %{instance: instance, command: command} do
      DoubleEntryLedger.MockCommandWorker
      |> expect(:process_command_with_id, fn _id, _processor_name ->
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
      |> expect(:process_command_with_id, fn _id, _processor_name ->
        raise "crash after max retries"
      end)

      {_pid, ref} = start_processor(instance.id)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      updated = CommandStore.get_by_id(command.id)
      assert updated.command_queue_item.status == :dead_letter
    end
  end
end
