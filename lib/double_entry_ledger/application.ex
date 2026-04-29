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
        # BYO-repo mode: consumer's repo must be up before Oban and the
        # command queue start, so the consumer supervises those via
        # `DoubleEntryLedger.children/0` in their own application.
        []
      end

    opts = [strategy: :one_for_one, name: DoubleEntryLedger.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  @spec managed_children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def managed_children do
    [
      if(@start_command_queue, do: {DoubleEntryLedger.CommandQueue.Supervisor, []}),
      {Oban, Application.fetch_env!(:double_entry_ledger, Oban)}
    ]
    |> Enum.reject(&is_nil/1)
  end
end
