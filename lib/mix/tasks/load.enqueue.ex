defmodule Mix.Tasks.Load.Enqueue do
  @moduledoc """
  Load-test the **enqueue-only path** of DoubleEntryLedger.

  Drives `CommandApi.create_from_params/1` with N concurrent workers:
  each call validates the param shape, hashes the idempotency key, and
  inserts a `Command` + `CommandQueueItem` row. **No transaction
  processing** is exercised — the queue is configured off via
  `start_command_queue: false` in `config/perf.exs`, so claimed work
  doesn't drain in the background.

  Use this task to measure how fast the producer side (the path real
  production callers funnel through) can push commands into the queue.

  ## Setup

  Drops the perf DB, creates a fresh one, migrates, starts the app.
  Requires `MIX_ENV=perf`.

  ## Usage

      MIX_ENV=perf mix load.enqueue [concurrency] [seconds]

  ## Arguments

  * `concurrency` — number of concurrent enqueue workers (default: 1)
  * `seconds` — duration in seconds (default: 10, accepts floats)

  ## Examples

      MIX_ENV=perf mix load.enqueue
      MIX_ENV=perf mix load.enqueue 10
      MIX_ENV=perf mix load.enqueue 10 30

  ## See also

  * `mix load.process` — full processing path (`process_new_command/1`).
  * `mix load.drain` — consumer-only K=1 drain via `InstanceProcessor`.
  """
  use Mix.Task

  @shortdoc "Load-test the enqueue path (CommandApi.create_from_params/1) — :perf env"

  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load.enqueue`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    {concurrency, time} = parse_args(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_enqueue_load_test(concurrency, time)
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
