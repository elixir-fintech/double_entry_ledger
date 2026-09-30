defmodule DoubleEntryLedger.CommandQueue.InstanceProcessorSupervisionTest do
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.LeaseFixtures

  alias DoubleEntryLedger.CommandQueue.InstanceProcessor

  setup do
    start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

    start_supervised!({Task.Supervisor, name: DoubleEntryLedger.CommandQueue.WorkerSupervisor})

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one}
      )

    instance = instance_fixture()

    %{supervisor: supervisor, instance: instance, grant: test_grant(instance.id)}
  end

  test "processors are temporary dynamic children", %{instance: instance, grant: grant} do
    assert %{restart: :temporary} =
             InstanceProcessor.child_spec(instance_id: instance.id, grant: grant)
  end

  test "processors get a shutdown window to release their lease", %{
    instance: instance,
    grant: grant
  } do
    assert %{shutdown: 10_000} =
             InstanceProcessor.child_spec(instance_id: instance.id, grant: grant)
  end

  test "an empty processor exits without restarting its supervisor", %{
    supervisor: supervisor,
    instance: instance,
    grant: grant
  } do
    assert {:ok, processor} =
             DynamicSupervisor.start_child(
               DoubleEntryLedger.CommandQueue.InstanceSupervisor,
               {InstanceProcessor, instance_id: instance.id, grant: grant}
             )

    processor_ref = Process.monitor(processor)

    assert_receive {:DOWN, ^processor_ref, :process, ^processor, :normal}, 5_000

    assert DynamicSupervisor.count_children(supervisor) == %{
             specs: 0,
             active: 0,
             supervisors: 0,
             workers: 0
           }

    assert Process.whereis(DoubleEntryLedger.CommandQueue.InstanceSupervisor) == supervisor
  end
end
