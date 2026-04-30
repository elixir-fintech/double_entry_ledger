defmodule Mix.Tasks.Load.Process do
  @moduledoc """
  Load-test the **full processing path** of DoubleEntryLedger.

  Drives `CommandWorker.process_new_command/1` directly with N concurrent
  workers — bypasses the queue entirely. Each call validates the
  command, inserts the `Command` + `CommandQueueItem`, runs the full
  `Ecto.Multi` (transaction + entries + account updates +
  balance_history_entries + journal_event), and marks the command as
  `:processed`.

  Use this task to measure the synchronous in-memory ceiling for the
  full end-to-end command lifecycle, decoupled from the queue's
  claim/reschedule overhead.

  ## Setup

  Drops the perf DB, creates a fresh one, migrates, starts the app.
  Requires `MIX_ENV=perf`.

  ## Usage

      MIX_ENV=perf mix load.process [concurrency] [seconds]

  ## Arguments

  * `concurrency` — number of concurrent workers (default: 1)
  * `seconds` — duration in seconds (default: 10, accepts floats)

  ## Examples

      MIX_ENV=perf mix load.process
      MIX_ENV=perf mix load.process 10
      MIX_ENV=perf mix load.process 10 30

  ## See also

  * `mix load.enqueue` — producer-only path (`create_from_params/1`).
  * `mix load.drain` — consumer-only K=1 drain via `InstanceProcessor`.
  """
  use Mix.Task

  @shortdoc "Load-test the full processing path (process_new_command/1) — :perf env"

  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load.process`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    {concurrency, time} = parse_args(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_load_test(concurrency, time)
  end

  defp parse_args([concurrency_str, time_str | _]) do
    concurrency =
      case Integer.parse(concurrency_str) do
        {c, _} -> c
        :error -> 1
      end

    time =
      case Float.parse(time_str) do
        {t, _} -> t
        :error -> 10
      end

    {concurrency, time}
  end

  defp parse_args([concurrency_str | _]) do
    case Integer.parse(concurrency_str) do
      {concurrency, _} -> {concurrency, 10}
      :error -> {1, 10}
    end
  end

  defp parse_args(_), do: {1, 10}
end
