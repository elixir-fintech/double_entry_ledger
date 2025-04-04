defmodule Mix.Tasks.LoadTest do
  @moduledoc """
  Run a load test for DoubleEntryLedger
  """
  use Mix.Task

  @shortdoc "Run a load test for DoubleEntryLedger"

  # Silence warnings about DoubleEntryLedger.LoadTesting being undefined
  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      # halt the task if the environment is not perf
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load_test`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    concurrency = parse_concurrency(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_load_test(concurrency)
  end

  defp parse_concurrency([concurrency_str | _]) do
    case Integer.parse(concurrency_str) do
      {concurrency, _} -> concurrency
      :error -> 1
    end
  end

  defp parse_concurrency(_), do: 1
end
