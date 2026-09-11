defmodule Mix.Tasks.Load.MultiDrain do
  @moduledoc """
  Multi-instance horizontal-scaling consumer load test.

  Runs `N` `InstanceProcessor`s in parallel, one per instance, each
  draining `K` pre-filled commands. Reports per-instance and
  aggregate throughput so the per-instance K=1 ceiling can be
  multiplied out and the linear-scaling claim validated.

  Separate instances have non-overlapping accounts and disjoint
  queue partitions, so M `InstanceProcessor`s on M instances should
  give roughly M × per-instance-tps aggregate throughput. This task
  measures how close we get.

  Pre-fill is parallelized via `Task.async_stream` and **not**
  included in the measurement — only the drain phase is timed.

  Requires `start_command_queue: false` so the library's own queue supervision
  isn't competing for the instances under test. This repository sets it in
  `config/perf.exs`.

  ## Setup

  Drops the perf DB, creates a fresh one, migrates, starts the app.
  Requires `MIX_ENV=perf`.

  ## Usage

      MIX_ENV=perf mix load.multi_drain [N] [K]

  ## Arguments

  * `N` — number of instances / parallel `InstanceProcessor`s (default: 4)
  * `K` — pre-filled commands per instance (default: 5000)

  ## Examples

      BATCH=on BATCH_SIZE=64 MIX_ENV=perf mix load.multi_drain
      BATCH=on BATCH_SIZE=64 MIX_ENV=perf mix load.multi_drain 1 5000
      BATCH=on BATCH_SIZE=64 MIX_ENV=perf mix load.multi_drain 8 5000

  ## See also

  * `mix load.drain` — **production consumer (K=1)**: single
    instance, single `InstanceProcessor`. Run this first to
    establish the per-instance ceiling that `load.multi_drain`
    multiplies out.
  """
  use Mix.Task

  @shortdoc "Multi-instance consumer scaling (N parallel InstanceProcessors) — :perf env"

  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load.multi_drain`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    {n_instances, prefill_per_instance} = parse_args(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_multi_drain_load_test(n_instances, prefill_per_instance)
  end

  defp parse_args([n_str, k_str | _]) do
    {parse_positive(n_str, 4, "N"), parse_positive(k_str, 5_000, "K")}
  end

  defp parse_args([n_str | _]) do
    {parse_positive(n_str, 4, "N"), 5_000}
  end

  defp parse_args(_), do: {4, 5_000}

  defp parse_positive(str, _default, label) do
    case Integer.parse(str) do
      {n, _} when n > 0 ->
        n

      _ ->
        Mix.raise("Invalid #{label}=#{inspect(str)}: must be a positive integer")
    end
  end
end
