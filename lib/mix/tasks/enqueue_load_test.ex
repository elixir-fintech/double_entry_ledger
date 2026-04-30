defmodule Mix.Tasks.EnqueueLoadTest do
  @moduledoc """
  Mix task for measuring the **enqueue-only** path of DoubleEntryLedger.

  Drives `CommandApi.create_from_params/1` repeatedly: each call validates
  the param shape, hashes the idempotency key, and inserts a `Command` +
  `CommandQueueItem` row. No transaction processing is exercised — the
  queue is configured off via `start_command_queue: false` in
  `config/perf.exs`, so claimed work doesn't drain in the background.

  Use this task to measure how fast the producer side (the path real
  production callers funnel through) can push commands into the queue.

  ## Setup

  Same as `mix load_test` — drops the perf DB, creates a fresh one,
  migrates, and runs.

  ## Usage

      MIX_ENV=perf mix enqueue_load_test [concurrency] [seconds]

  ## Options

  * `concurrency` - Optional integer specifying the number of concurrent
    enqueuing processes (default: 1).
  * `seconds` - Optional float specifying the duration in seconds
    (default: 10).

  ## Examples

      MIX_ENV=perf mix enqueue_load_test
      MIX_ENV=perf mix enqueue_load_test 10
      MIX_ENV=perf mix enqueue_load_test 10 30

  ## Requirements

  This task depends on `DoubleEntryLedger.LoadTesting`, which must
  define `run_enqueue_load_test/2` accepting `(concurrency, seconds)`.
  """
  use Mix.Task

  @shortdoc "Run an enqueue-only load test (CommandApi.create_from_params/1) — requires :perf env"

  # Silence warnings about DoubleEntryLedger.LoadTesting being undefined
  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix enqueue_load_test`"
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
