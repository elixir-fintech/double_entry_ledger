defmodule DoubleEntryLedger.CommandQueue.Coordinator.DatabasePollingTest do
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.LeaseFixtures

  alias DoubleEntryLedger.CommandQueue.Coordinator.DatabasePolling
  alias DoubleEntryLedger.Stores.CommandStore

  setup :create_instance

  setup do
    start_supervised!({Registry, keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry})
    %{state: DatabasePolling.init([])}
  end

  test "candidates/1 includes a free ledger with work", %{instance: instance, state: state} do
    {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: instance.address))
    {ids, _state} = DatabasePolling.candidates(state)
    assert instance.id in ids
  end

  test "candidates/1 excludes a reserved ledger", %{instance: instance, state: state} do
    {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: instance.address))
    {:ok, _reservation, state} = DatabasePolling.reserve(instance.id, state)
    {ids, _state} = DatabasePolling.candidates(state)
    refute instance.id in ids
  end

  test "candidates/1 excludes a locally registered ledger", %{instance: instance, state: state} do
    {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: instance.address))
    {:ok, _} = Registry.register(DoubleEntryLedger.CommandQueue.Registry, instance.id, nil)
    {ids, _state} = DatabasePolling.candidates(state)
    refute instance.id in ids
  end

  test "candidates/1 excludes a ledger with a live lease", %{instance: instance, state: state} do
    {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: instance.address))
    _grant = test_grant(instance.id)
    {ids, _state} = DatabasePolling.candidates(state)
    refute instance.id in ids
  end

  test "reserve/2 reserves a free id once and skips it the second time", %{
    instance: instance,
    state: state
  } do
    {:ok, reservation, state} = DatabasePolling.reserve(instance.id, state)
    assert reservation == instance.id
    assert {:skip, _state} = DatabasePolling.reserve(instance.id, state)
  end

  test "reserve/2 skips a locally registered ledger", %{instance: instance, state: state} do
    {:ok, _} = Registry.register(DoubleEntryLedger.CommandQueue.Registry, instance.id, nil)
    assert {:skip, _state} = DatabasePolling.reserve(instance.id, state)
  end

  test "a reservation outlives the acquisition task once the processor started", %{
    instance: instance,
    state: state
  } do
    {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: instance.address))
    {:ok, r, state} = DatabasePolling.reserve(instance.id, state)
    state = DatabasePolling.acquisition_started(r, make_ref(), state)
    state = DatabasePolling.processor_started(r, self(), state)

    assert {:skip, _} = DatabasePolling.reserve(instance.id, state)
    {ids, _} = DatabasePolling.candidates(state)
    refute instance.id in ids
  end

  test "release/2 frees the id", %{instance: instance, state: state} do
    {:ok, r, state} = DatabasePolling.reserve(instance.id, state)
    state = DatabasePolling.release(r, state)
    assert {:ok, _, _} = DatabasePolling.reserve(instance.id, state)
  end

  test "a fresh state still excludes a ledger whose processor is registered locally", %{
    instance: instance
  } do
    {:ok, _} = CommandStore.create(transaction_command_attrs(instance_address: instance.address))
    {:ok, _} = Registry.register(DoubleEntryLedger.CommandQueue.Registry, instance.id, nil)
    fresh = DatabasePolling.init([])

    assert {:skip, _} = DatabasePolling.reserve(instance.id, fresh)
    {ids, _} = DatabasePolling.candidates(fresh)
    refute instance.id in ids
  end
end
