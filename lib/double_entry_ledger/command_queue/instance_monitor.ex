defmodule DoubleEntryLedger.CommandQueue.InstanceMonitor do
  @moduledoc """
  Monitors the command queue for pending commands and ensures processors are started as needed.

  ## Overview

  The `InstanceMonitor` is a GenServer responsible for periodically scanning the database
  for instances that have commands requiring processing. For each such instance,
  it ensures that an `InstanceProcessor` is running to handle those commands.

  ## Responsibilities

    * Recover commands stranded in `:processing` by an owner that disappeared.
    * Periodically poll the database for instances with pending, failed, or timed-out commands.
    * For each instance with processable commands, ensure an `InstanceProcessor` is started.
    * Avoid starting duplicate processors for the same instance by checking the Registry.
    * Answer `wake/1` so a freshly enqueued command does not wait for the next poll.
    * Use application configuration for poll interval (`:poll_interval` in `:command_queue` config).

  ## Waking on enqueue

  On an otherwise idle queue the poll interval is pure latency: nothing runs
  until the next `:poll`. `DoubleEntryLedger.Stores.CommandStore` therefore
  calls `wake/1` after a successful enqueue when no processor is registered for
  that instance, and this module ensures a processor for that one instance.

  The wake is an optimization only. It runs no recovery sweep and no discovery
  query, it is best-effort (see `wake/1`), and the poll remains the guarantee
  that processable work is eventually picked up.

  ## Stale `:processing` recovery

  A command claimed by a node that then dies leaves its queue row in
  `:processing` forever: the in-memory processor and task are gone, and
  `:processing` is not a state the discovery query looks at. Every poll
  therefore starts with a sweep (`recover_stale_processing_commands/1`) that
  finds rows which have been `:processing` for longer than
  `:stale_processing_after`, compared on the PostgreSQL clock, and routes each
  one through the ordinary failure path
  (`CommandQueue.Scheduling.schedule_retry_with_reason/4`). That reuse gives
  retry bookkeeping, exponential backoff, automatic dead-lettering past
  `:max_retries`, and the reason appended to the row's errors. A recovery that
  schedules a retry also clears `processor_id`; one that dead-letters preserves
  it, matching `CommandQueueItem.dead_letter_changeset/2`, so the processor
  that stranded the command stays visible for diagnosis.

  The recovery write carries `optimistic_lock(:processor_version)`, so it is
  fenced both ways: it invalidates a merely slow former owner's later write,
  and if that owner (or a new one) got there first the recovery raises
  `Ecto.StaleEntryError`, which is logged and skipped — an expected race, not
  an error.

  ## Configuration

  The poll interval and the staleness threshold can be set in your
  application config:

      config :double_entry_ledger, :command_queue,
        poll_interval: 5_000,
        stale_processing_after: 300

  `:poll_interval` is in milliseconds and defaults to 5,000 (5 seconds).
  `:stale_processing_after` is in seconds, like `:base_retry_delay` and
  `:max_retry_delay`, and defaults to 300 (5 minutes). It should comfortably
  exceed the longest expected command processing time, otherwise live work is
  recovered out from under its owner (the fence keeps that safe, but the work
  is redone).

  ## Process Supervision

  This module is intended to be supervised as part of the command queue supervision tree.
  """
  use GenServer
  require Logger

  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.CommandQueue.{InstanceProcessor, Scheduling}
  alias DoubleEntryLedger.Telemetry

  # Rows recovered per poll. Stranded rows are expected to be rare, so this is
  # only a guard against one poll stalling on a large backlog; the remainder is
  # picked up by the next poll.
  @stale_recovery_limit 100

  # Fallback when `:stale_processing_after` is not configured, in seconds.
  @default_stale_processing_after 300

  # Client API

  @doc """
  Starts the InstanceMonitor GenServer.

  This function is typically called by the supervisor and does not need to be called directly.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Asks the monitor to ensure a processor for `instance_id` now, instead of on
  its next poll, and returns `:ok`.

  Best-effort by design and never blocks the caller:

    * `GenServer.cast/2` to an unregistered name is a silent no-op, so this is
      safe when the command queue is not supervised at all (for example
      `start_command_queue: false`).
    * The woken processor may find nothing to do and shut straight back down —
      see `DoubleEntryLedger.Stores.CommandStore` for why an enqueue is not
      necessarily visible yet — in which case the next poll picks the work up.

  The Registry lookup runs in the calling process and is an ETS read, so a
  burst of enqueues for one instance does not put one message per command into
  this monitor's single mailbox: once a processor is registered, further wakes
  cost a lookup and nothing more. A running processor drains the instance on
  its own.
  """
  @spec wake(Ecto.UUID.t()) :: :ok
  def wake(instance_id) do
    case Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance_id) do
      [] -> GenServer.cast(__MODULE__, {:wake, instance_id})
      [_ | _] -> :ok
    end
  rescue
    # No Registry means the command queue is not supervised in this runtime.
    ArgumentError -> :ok
  end

  # Server Callbacks

  @impl true
  @doc false
  def init(_) do
    config = Application.get_env(:double_entry_ledger, :command_queue, [])
    poll_interval = Keyword.get(config, :poll_interval, 5_000)

    # Validate up front so a bad threshold fails at startup rather than
    # crash-looping the poll.
    _ = stale_processing_after()

    schedule_poll(poll_interval)
    {:ok, %{poll_interval: poll_interval}}
  end

  @doc """
  Recovers commands stranded in `:processing` past the configured threshold by
  sending each one back through the normal failure path, and returns `:ok`.

  Runs on every poll before instance discovery. `repo` exists so tests can
  stage the ownership race between the sweep's read and its write; callers
  should use the default.
  """
  @spec recover_stale_processing_commands(Ecto.Repo.t()) :: :ok
  def recover_stale_processing_commands(repo \\ Repo) do
    stale_after = stale_processing_after()

    stale_after
    |> Scheduling.stale_processing_commands_query(@stale_recovery_limit)
    |> repo.all()
    |> Enum.each(&recover_stale_command(&1, stale_after, repo))
  end

  @impl true
  @doc false
  def handle_cast({:wake, instance_id}, state) do
    # Targeted wake: one instance, no recovery sweep and no discovery query.
    # `ensure_processor/1` is Registry-guarded, so a redundant wake is a no-op.
    ensure_processor(instance_id)
    {:noreply, state}
  end

  @impl true
  @doc false
  def handle_info(:poll, state) do
    recover_stale_processing_commands()
    monitor_instances()
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  # Private functions

  # `stale_for_seconds` and the staleness test both come from the database
  # clock, so the recovery decision never depends on this node's time.
  @spec recover_stale_command(
          {Command.t(), DoubleEntryLedger.CommandQueueItem.t(), float()},
          non_neg_integer(),
          Ecto.Repo.t()
        ) :: :ok
  defp recover_stale_command({command, queue_item, stale_for_seconds}, stale_after, repo) do
    previous_processor_id = queue_item.processor_id
    stale_for = round(stale_for_seconds)

    reason =
      "stranded in :processing for #{stale_for}s under processor " <>
        "#{inspect(previous_processor_id)} (threshold #{stale_after}s); " <>
        "recovered by InstanceMonitor"

    %{command | command_queue_item: queue_item}
    |> Scheduling.schedule_retry_with_reason(reason, :failed, repo)
    |> emit_recovery(previous_processor_id, stale_for)
  rescue
    # The former owner finished, or another processor claimed the row, between
    # this sweep's read and its write. Expected; the row is theirs now.
    Ecto.StaleEntryError ->
      Logger.info(
        "skipping recovery of command #{command.id}: " <>
          "its claim moved on from processor #{inspect(queue_item.processor_id)}"
      )
  end

  @spec emit_recovery({:error, Command.t() | Ecto.Changeset.t()}, String.t() | nil, integer()) ::
          :ok
  defp emit_recovery({:error, %Command{} = command}, previous_processor_id, stale_for) do
    Telemetry.command_recovered(%{
      command_id: command.id,
      instance_id: command.instance_id,
      previous_processor_id: previous_processor_id,
      stale_for_seconds: stale_for,
      trace_context: command.trace_context
    })
  end

  defp emit_recovery({:error, %Ecto.Changeset{} = changeset}, _previous_processor_id, _stale_for) do
    Logger.error("could not recover stale command: #{inspect(changeset.errors)}")
  end

  # Read and validate together: a zero or negative threshold would make every
  # `:processing` row instantly stale and recover live work on every poll, and
  # a non-integer would reach PostgreSQL as a query parameter and crash the
  # poll. `init/1` calls this so bad configuration fails at startup.
  @spec stale_processing_after() :: pos_integer()
  defp stale_processing_after do
    :double_entry_ledger
    |> Application.get_env(:command_queue, [])
    |> Keyword.get(:stale_processing_after, @default_stale_processing_after)
    |> validate_stale_processing_after()
  end

  @spec validate_stale_processing_after(term()) :: pos_integer()
  defp validate_stale_processing_after(seconds) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp validate_stale_processing_after(other) do
    raise ArgumentError,
          ":stale_processing_after must be a positive integer number of seconds, " <>
            "got: #{inspect(other)}"
  end

  defp monitor_instances do
    # Find instances with processable commands
    instances_with_commands = find_instances_with_commands()

    # Start processors for each instance
    Enum.each(instances_with_commands, &ensure_processor/1)
  end

  defp find_instances_with_commands do
    # Distinct instance IDs with processable commands, evaluated on the
    # database clock.
    Repo.all(Scheduling.instances_with_processable_commands_query())
  end

  defp ensure_processor(instance_id) do
    # Check if processor already exists
    case Registry.lookup(DoubleEntryLedger.CommandQueue.Registry, instance_id) do
      [] ->
        # No processor running, start one
        Logger.info("Starting new processor for instance #{instance_id}")

        DynamicSupervisor.start_child(
          DoubleEntryLedger.CommandQueue.InstanceSupervisor,
          {InstanceProcessor, [instance_id: instance_id]}
        )

      [{pid, _}] ->
        # Processor already running
        Logger.debug("Processor already running for instance #{instance_id}: #{inspect(pid)}")
        :ok
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
