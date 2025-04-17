defmodule Mix.Tasks.LoadTest do
  @moduledoc """
  Mix task for running performance load tests on the Double Entry Ledger system.

  This task executes a series of load tests to evaluate the system's performance
  under concurrent transaction processing. It's designed specifically for performance
  testing and requires the `:perf` environment to ensure isolation from development
  or production databases.

  ## Setup

  The task automatically:
  * Drops any existing database to ensure a clean state
  * Creates a new database
  * Runs migrations to set up the schema
  * Starts the application

  ## Usage

    MIX_ENV=perf mix load_test [concurrency]

  ## Options

  * `concurrency` - Optional integer specifying the number of concurrent processes to use
  in the load test (default: 1)

  ## Examples

  Run with default concurrency:
    MIX_ENV=perf mix load_test

  Run with specified concurrency:
    MIX_ENV=perf mix load_test 10

  ## Requirements

  This task depends on the `DoubleEntryLedger.LoadTesting` module, which must be
  defined and implement a `run_load_test/1` function that accepts a concurrency level
  """
  use Mix.Task

  @shortdoc "Run a load test for DoubleEntryLedger, requires :perf environment, accepts concurrency argument"

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
