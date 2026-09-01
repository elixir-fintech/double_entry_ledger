defmodule DoubleEntryLedger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @start_command_queue Application.compile_env(:double_entry_ledger, :start_command_queue, true)

  @impl true
  def start(_type, _args) do
    children =
      if DoubleEntryLedger.Config.repo() == DoubleEntryLedger.Repo do
        # Standalone mode: library owns its repo and supervises everything.
        [DoubleEntryLedger.Repo | DoubleEntryLedger.children()]
      else
        # BYO-repo mode: the consumer's repo must be up before the command
        # queue starts, so the consumer supervises it via
        # `DoubleEntryLedger.children/0` in their own application.
        []
      end

    opts = [strategy: :one_for_one, name: DoubleEntryLedger.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  @spec managed_children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def managed_children do
    if @start_command_queue do
      [{DoubleEntryLedger.CommandQueue.Supervisor, []}]
    else
      []
    end
  end
end
