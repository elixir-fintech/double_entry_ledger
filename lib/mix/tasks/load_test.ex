defmodule Mix.Tasks.LoadTest do
  @moduledoc """
  Run a load test for DoubleEntryLedger
  """
  use Mix.Task

  @shortdoc "Run a load test for DoubleEntryLedger"

  def run(args) do
    if Mix.env != :perf do
      #halt the task if the environment is not perf
      Mix.raise("This task can only be run in the perf environment")
    end
    Mix.Task.run("ecto.drop", [])
    Mix.Task.run("ecto.create", [])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    concurrency = parse_concurrency(args)
    DoubleEntryLedger.LoadTesting.run_load_test(concurrency)
  end

  defp parse_concurrency([concurrency_str |_]) do
    case Integer.parse(concurrency_str) do
      {concurrency, _} -> concurrency
      :error -> 1
    end
  end

  defp parse_concurrency(_), do: 1
end
