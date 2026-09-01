defmodule Mix.Tasks.Load.Enqueue do
  @moduledoc """
  Production producer-side load test.

  Drives `CommandApi.create_from_params/1` with N concurrent workers
  — **the same public API real production callers use to enqueue
  commands**. Each call:

    1. Validates the param shape (`TransactionCommandMap.create/1`).
    2. Hashes the idempotency key (`Command.IdempotencyKey`).
    3. Inserts the `Command` + `CommandQueueItem` rows in one txn.

  No transaction processing is exercised here. Set
  `start_command_queue: false` so work doesn't drain in the background. This
  repository does so in `config/perf.exs`.

  Use this task to measure how fast the **producer** side can push
  commands into the queue, in isolation from the consumer.

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

  * `mix load.drain` — **production consumer (K=1)**: drains a
    pre-filled queue with one `InstanceProcessor`. Pair this with
    `load.enqueue` to model the full production lifecycle.
  * `mix load.process` — synthetic in-process baseline that bypasses
    both the queue and the public API. Useful for comparing against
    end-to-end production cost.
  """
  use Mix.Task

  @shortdoc "Production producer (CommandApi.create_from_params/1) — :perf env"

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
