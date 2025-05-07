defmodule DoubleEntryLedger.EventQueue.Supervisor do
  @moduledoc """
  Supervises the event queue system components.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: DoubleEntryLedger.EventQueue.Registry},
      {DynamicSupervisor,
       name: DoubleEntryLedger.EventQueue.InstanceSupervisor, strategy: :one_for_one},
      {DoubleEntryLedger.EventQueue.InstanceMonitor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
