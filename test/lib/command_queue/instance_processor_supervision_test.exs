defmodule DoubleEntryLedger.CommandQueue.InstanceProcessorSupervisionTest do
  use DoubleEntryLedger.RepoCase, async: false

  alias DoubleEntryLedger.CommandQueue.InstanceProcessor

  setup do
    start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         name: DoubleEntryLedger.CommandQueue.InstanceSupervisor, strategy: :one_for_one}
      )

    %{supervisor: supervisor}
  end

  test "processors are temporary dynamic children" do
    instance_id = Ecto.UUID.generate()

    assert %{restart: :temporary} = InstanceProcessor.child_spec(instance_id: instance_id)
  end

  test "an empty processor exits without restarting its supervisor", %{supervisor: supervisor} do
    instance_id = Ecto.UUID.generate()

    assert {:ok, processor} =
             DynamicSupervisor.start_child(
               DoubleEntryLedger.CommandQueue.InstanceSupervisor,
               {InstanceProcessor, instance_id: instance_id}
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
