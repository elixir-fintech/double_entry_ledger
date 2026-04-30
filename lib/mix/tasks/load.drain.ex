defmodule Mix.Tasks.Load.Drain do
  @moduledoc """
  Production consumer-side load test (K=1).

  Pre-fills the queue with N pending commands (via the production
  producer path, `CommandApi.create_from_params/1`), then starts a
  single `InstanceProcessor` and times how long it takes to drain.

  This measures the **K=1 consumer ceiling**: one
  `InstanceProcessor` per instance claiming and processing commands
  one at a time through `CommandWorker.process_command_with_id/2` —
  the actual production consumer code path.

  Pre-fill is parallelized via `Task.async_stream` but **not**
  included in the measurement. Only the drain phase is timed.

  Requires `start_command_queue: false` in `config/perf.exs` (the
  perf default) so the library's own queue supervision isn't
  competing for the same instance.

  ## Setup

  Drops the perf DB, creates a fresh one, migrates, starts the app.
  Requires `MIX_ENV=perf`.

  ## Usage

      MIX_ENV=perf mix load.drain [prefill_count]

  ## Arguments

  * `prefill_count` — number of commands to enqueue before draining.
    Bigger means more steady-state, longer test (default: 10000).

  ## Examples

      MIX_ENV=perf mix load.drain
      MIX_ENV=perf mix load.drain 5000
      MIX_ENV=perf mix load.drain 50000

  ## See also

  * `mix load.enqueue` — **production producer**:
    `CommandApi.create_from_params/1`. Pair with `load.drain` to
    model the full production lifecycle.
  * `mix load.process` — synthetic in-process baseline that bypasses
    both the queue and the public API. Useful for comparing against
    the end-to-end production cost measured by enqueue + drain.
  """
  use Mix.Task

  @shortdoc "Production consumer K=1 drain (single InstanceProcessor) — :perf env"

  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load.drain`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    prefill_count = parse_args(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_drain_load_test(prefill_count)
  end

  defp parse_args([prefill_str | _]) do
    case Integer.parse(prefill_str) do
      {n, _} when n > 0 -> n
      _ -> 10_000
    end
  end

  defp parse_args(_), do: 10_000
end
