defmodule Mix.Tasks.Load.MixedDrain do
  @moduledoc """
  Mixed-workload consumer-side load test (K=1) for the create+update
  batching path — the gate `mix load.drain` is for create-only.

  Two-phase: pre-fill N :pending creates, drain them (not measured),
  pre-fill M updates targeting those creates, drain (MEASURED). The
  reported tps is `M / phase4_elapsed`.

  Use a 1:1 ratio (`create_count == update_count`) to model the
  B7 "50/50 mixed corpus" workload.

  ## Setup

  Drops the perf DB, creates fresh, migrates, starts the app.
  Requires `MIX_ENV=perf`.

  ## Usage

      MIX_ENV=perf mix load.mixed_drain [create_count] [update_count]

  ## Arguments

  * `create_count` — number of :pending creates pre-filled in phase 1
    (default 5000).
  * `update_count` — number of updates pre-filled in phase 3
    (default = `create_count`; must be ≤ `create_count`).

  ## Examples

      MIX_ENV=perf mix load.mixed_drain
      MIX_ENV=perf mix load.mixed_drain 10000
      MIX_ENV=perf mix load.mixed_drain 10000 5000

  ## See also

  * `mix load.drain` — pure-create K=1 drain (Phase A's gate).
  """
  use Mix.Task

  @shortdoc "Mixed-workload consumer K=1 drain (creates + updates) — :perf env"

  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load.mixed_drain`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    {create_count, update_count} = parse_args(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_mixed_drain_load_test(create_count, update_count)
  end

  defp parse_args([create_str, update_str | _]) do
    {parse_positive(create_str, 5000), parse_positive(update_str, 5000)}
  end

  defp parse_args([create_str | _]) do
    n = parse_positive(create_str, 5000)
    {n, n}
  end

  defp parse_args(_), do: {5000, 5000}

  defp parse_positive(str, default) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
end
