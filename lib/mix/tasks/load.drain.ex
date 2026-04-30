defmodule Mix.Tasks.Load.Drain do
  @moduledoc """
  Load-test the **consumer-only K=1 drain path** of DoubleEntryLedger.

  Pre-fills the queue with N pending commands (via
  `CommandApi.create_from_params/1`), then starts a single
  `InstanceProcessor` and times how long it takes to drain. Reports the
  drain throughput in transactions per second — the K=1 (one processor
  per instance), single-instance consumer ceiling.

  Pre-fill is parallelized but **not** included in the measurement.
  Only the drain phase is timed.

  Requires `start_command_queue: false` in `config/perf.exs` (the perf
  default) so the library's own queue supervision isn't competing for
  the same instance.

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

  * `mix load.process` — full processing path (`process_new_command/1`).
  * `mix load.enqueue` — producer-only path (`create_from_params/1`).
  """
  use Mix.Task

  @shortdoc "Drain a pre-filled queue with one InstanceProcessor (K=1) — :perf env"

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
