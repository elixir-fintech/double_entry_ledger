defmodule DoubleEntryLedger.CommandQueue.Scheduling do
  @moduledoc """
  Provides scheduling helpers for commands in the command queue.

  It exposes functions that manage the full lifecycle of a command in the queue:

  * Scheduling and retrying failed commands with exponential backoff
  * Managing transitions between different command states (pending, processing, failed, dead letter)
  * Handling special cases like updates waiting for create commands
  * Adding errors and tracking retry attempts

  The scheduling system uses configurable parameters:
  * Maximum number of retries before a command is sent to dead letter
  * Base delay for first retry attempt
  * Maximum delay cap to prevent excessive wait times
  * Jitter to prevent thundering herd problems during retries
  """

  require Logger
  alias DoubleEntryLedger.Telemetry
  alias DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError
  import Ecto.Changeset, only: [change: 2, put_assoc: 3]
  import Ecto.Query, only: [from: 2]

  alias DoubleEntryLedger.Command

  alias DoubleEntryLedger.Repo.Proxy, as: Repo

  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.CommandQueueItem
  alias Ecto.Changeset

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()

  @config Application.compile_env(:double_entry_ledger, :command_queue, [])
  @max_retries Keyword.get(@config, :max_retries, 5)
  @base_delay Keyword.get(@config, :base_retry_delay, 30)
  @max_delay Keyword.get(@config, :max_retry_delay, 3600)

  @processable_states [:pending, :occ_timeout, :failed]

  @doc """
  Sets the next retry time for a failed command using exponential backoff.

  ## Parameters
    - `command` - The command that failed and needs retry scheduling
    - `error` - The error message or reason for failure
    - `status` - The status to set for the command (defaults to `:failed`)

  ## Returns
    - `{:error, updated_command}` - The command with updated retry information
    - `{:error, changeset}` - Error updating the command
  """
  @spec schedule_retry_with_reason(
          Command.t(),
          String.t(),
          CommandQueueItem.state(),
          Ecto.Repo.t()
        ) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  def schedule_retry_with_reason(command, reason, status, repo \\ Repo) do
    case build_schedule_retry_with_reason(command, reason, status) |> repo.update() do
      {:ok, command} ->
        {:error, command}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec mark_as_dead_letter(Command.t(), String.t(), Ecto.Repo.t()) ::
          {:error, Command.t()} | {:error, Changeset.t()}
  def mark_as_dead_letter(command, error, repo \\ Repo) do
    case build_mark_as_dead_letter(command, error) |> repo.update() do
      {:ok, command} ->
        {:error, command}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Claims a command for processing by marking it as being processed by a specific processor.

  This function implements optimistic concurrency control to ensure that only one processor
  can claim a command at a time. It only allows claiming commands with status :pending or :occ_timeout.

  ## Parameters
    - `id`: The UUID of the command to claim
    - `processor_id`: A string identifier for the processor claiming the command (defaults to "manual")
    - `repo`: The Ecto repository to use (defaults to Repo)

  ## Returns
    - `{:ok, command}`: If the command was successfully claimed
    - `{:error, :command_not_found}`: If no command with the given ID exists
    - `{:error, :command_already_claimed}`: If the command was claimed by another processor
    - `{:error, :command_not_claimable}`: If the command is not in a claimable state (not pending or occ_timeout)
  """
  @spec claim_command_for_processing(Ecto.UUID.t(), String.t(), Ecto.Repo.t()) ::
          {:ok, Command.t()} | {:error, atom()}
  def claim_command_for_processing(id, processor_id, repo \\ Repo) do
    case CommandStore.get_by_id(id) do
      nil ->
        {:error, :command_not_found}

      %{command_queue_item: %{status: state} = eqi} = command when state in @processable_states ->
        try do
          case Command.processing_start_changeset(
                 command,
                 processor_id,
                 retry_count_by_status(eqi)
               )
               |> repo.update() do
            {:ok, claimed} = result ->
              Telemetry.command_claim(%{
                command_id: claimed.id,
                instance_id: claimed.instance_id,
                processor_id: processor_id,
                trace_context: claimed.trace_context
              })

              result

            error ->
              error
          end
        rescue
          Ecto.StaleEntryError ->
            {:error, :command_already_claimed}
        end

      _ ->
        {:error, :command_not_claimable}
    end
  end

  @doc """
  Claims a batch of commands for processing — the bulk equivalent of
  `claim_command_for_processing/2`.

  Mirrors `CommandQueueItem.processing_start_changeset/3` for every command:
  status → `:processing`, stamps `processor_id`, clears `next_retry_after`,
  advances `processor_version`, and bumps
  `retry_count` per `retry_count_by_status/1` (unchanged for `:pending`,
  `+1` otherwise). A single conditional bulk update applies the appropriate
  retry-count rule to each row. The queue trigger stamps
  `processing_started_at`.

  The status and retry-time guards in the UPDATE are the concurrency check
  (in place of the single-row `optimistic_lock`): a command already claimed
  by another processor, or rescheduled for a future retry, is skipped.

  Returns the subset of `commands` that were actually claimed, in the same
  order, each with a refreshed `command_queue_item`. Commands that raced
  out of a claimable state are omitted.
  """
  @spec claim_batch_for_processing([Command.t()], String.t(), Ecto.Repo.t()) :: [Command.t()]
  def claim_batch_for_processing(commands, processor_id, repo \\ Repo)

  def claim_batch_for_processing([], _processor_id, _repo), do: []

  def claim_batch_for_processing(commands, processor_id, repo) do
    now = DateTime.utc_now()
    ids = Enum.map(commands, & &1.id)

    {_count, claimed_items} =
      from(eqi in CommandQueueItem,
        prefix: ^@schema_prefix,
        where:
          eqi.command_id in ^ids and eqi.status in ^@processable_states and
            (eqi.status == :pending or is_nil(eqi.next_retry_after) or
               eqi.next_retry_after <= ^now),
        update: [
          set: [
            status: :processing,
            processor_id: ^processor_id,
            next_retry_after: nil,
            retry_count:
              fragment(
                "? + CASE WHEN ? IN ('occ_timeout', 'failed') THEN 1 ELSE 0 END",
                eqi.retry_count,
                eqi.status
              )
          ],
          inc: [processor_version: 1]
        ],
        select: eqi
      )
      |> repo.update_all([])

    items_by_command_id = Map.new(claimed_items, &{&1.command_id, &1})

    claimed_commands =
      commands
      |> Enum.filter(&Map.has_key?(items_by_command_id, &1.id))
      |> Enum.map(&%{&1 | command_queue_item: Map.fetch!(items_by_command_id, &1.id)})

    # Emit the same `[:command, :claim]` event the single-command path
    # emits (Telemetry.command_claim/1), one per claimed command.
    Enum.each(claimed_commands, fn command ->
      Telemetry.command_claim(%{
        command_id: command.id,
        instance_id: command.instance_id,
        processor_id: processor_id,
        trace_context: command.trace_context
      })
    end)

    claimed_commands
  end

  @doc """
  Builds a changeset to mark a command as processed.

  This function updates the queue item's status to `:processed` and clears its
  retry timestamp. The queue trigger stamps `processing_completed_at`.

  ## Parameters
    - `command` - The Command struct to update

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for marking the command as processed
  """
  @spec build_mark_as_processed(Command.t()) :: Changeset.t(Command.t())
  def build_mark_as_processed(%{command_queue_item: command_queue_item} = command) do
    command_queue_changeset =
      command_queue_item
      |> CommandQueueItem.processing_complete_changeset()

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_changeset)
  end

  @doc """
  Builds a changeset to revert a command to the pending state.

  Adds the provided error message to the queue item's errors list and
  changes the status to `:pending` to allow it to be reprocessed.

  ## Parameters
    - `command` - The command to revert to pending state
    - `error` - The error message to add to the command's errors

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_revert_to_pending(Command.t(), any()) :: Changeset.t()
  def build_revert_to_pending(%{command_queue_item: command_queue_item} = command, error) do
    command_queue_changeset =
      command_queue_item
      |> CommandQueueItem.revert_to_pending_changeset(error)

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_changeset)
  end

  @doc """
  Builds a changeset to schedule a retry for a failed command.

  Handles both normal retries and terminal failures (dead letter):
  - If the retry count exceeds the configured maximum, marks as dead letter
  - Otherwise, calculates the next retry time using exponential backoff
  - Sets the appropriate command status, clears processor reference, and adds the error

  ## Parameters
    - `command` - The command that needs to be retried
    - `error` - The error message to add to the command's errors
    - `status` - The status to set (usually :failed)

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_schedule_retry_with_reason(Command.t(), String.t() | nil, CommandQueueItem.state()) ::
          Changeset.t()
  def build_schedule_retry_with_reason(
        %{command_queue_item: command_queue_item} = command,
        error,
        status
      ) do
    retry_count = command_queue_item.retry_count || 0

    if retry_count >= @max_retries do
      # Max retries exceeded, mark as dead letter
      build_mark_as_dead_letter(
        command,
        "Max retry count (#{@max_retries}) exceeded: #{error || status}"
      )
    else
      Telemetry.command_retry(%{
        command_id: command.id,
        instance_id: command.instance_id,
        status: status,
        retry_count: retry_count,
        trace_context: command.trace_context
      })

      # Calculate next retry time with exponential backoff
      retry_delay = calculate_retry_delay(retry_count)

      command_queue_item_changeset =
        command_queue_item
        |> CommandQueueItem.schedule_retry_changeset(
          error,
          status,
          retry_delay
        )

      command
      |> change(%{})
      |> put_assoc(:command_queue_item, command_queue_item_changeset)
    end
  end

  @doc """
  Builds a changeset to schedule the retry of an update command that depends
  on a failed create command.

  Ensures that update commands don't retry before their prerequisite create commands
  by scheduling them after the create command's next retry time.

  ## Parameters
    - `command` - The update command that needs to be retried
    - `error` - An UpdateCommandError struct containing the create command and error details

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_schedule_update_retry(Command.t(), UpdateCommandError.t()) :: Changeset.t()
  def build_schedule_update_retry(%{command_queue_item: command_queue_item} = command, error) do
    command_queue_item_changeset =
      command_queue_item
      |> CommandQueueItem.schedule_update_retry_changeset(
        error,
        calculate_retry_delay(command_queue_item.retry_count)
      )

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_item_changeset)
  end

  @doc """
  Builds a changeset to mark a command as permanently failed (dead letter).

  This is used when a command has failed terminally and should not be retried.
  Adds the provided error message to the command's errors and sets the status
  to `:dead_letter`.

  ## Parameters
    - `command` - The command to mark as dead letter
    - `error` - The error message explaining why the command is being marked as dead letter

  ## Returns
    - `Ecto.Changeset.t()` - The changeset for updating the command
  """
  @spec build_mark_as_dead_letter(Command.t(), String.t()) :: Changeset.t()
  def build_mark_as_dead_letter(%{command_queue_item: command_queue_item} = command, error) do
    Logger.error("dead-lettering command #{command.id}: #{error}")

    Telemetry.command_dead_letter(%{
      command_id: command.id,
      instance_id: command.instance_id,
      error: error,
      trace_context: command.trace_context
    })

    command_queue_changeset =
      command_queue_item
      |> CommandQueueItem.dead_letter_changeset(error)

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, command_queue_changeset)
  end

  # Private function to calculate retry delay
  @spec calculate_retry_delay(non_neg_integer()) :: non_neg_integer()
  defp calculate_retry_delay(retry_count) do
    # Exponential backoff: base_delay * 2^retry_count
    delay = @base_delay * :math.pow(2, retry_count)
    delay = min(delay, @max_delay)
    # Add some jitter to prevent thundering herd
    jitter = :rand.uniform(div(trunc(delay), 10) + 1)

    trunc(delay + jitter)
  end

  @spec retry_count_by_status(CommandQueueItem.t()) :: non_neg_integer()
  defp retry_count_by_status(%{status: :pending, retry_count: retry_count}), do: retry_count
  defp retry_count_by_status(%{status: _, retry_count: retry_count}), do: retry_count + 1
end
