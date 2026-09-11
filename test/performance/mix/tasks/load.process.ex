defmodule Mix.Tasks.Load.Process do
  @moduledoc """
  Synthetic in-process per-call ceiling baseline.

  Drives `CommandWorker.process_new_command/1` directly with N
  concurrent workers. **This is not the production code path.** It
  skips both:

    1. The public API entry point (`CommandApi.create_from_params/1`
       or `process_from_params/2`) — so no string-key parsing, no
       `TransactionCommandMap.create/1` validation pass.
    2. The queue. Each command is processed inline in the calling
       process; no `InstanceProcessor`, no `command_queue_item` claim
       cycle.

  Each call still inserts `Command` + `CommandQueueItem`, runs the
  full `Ecto.Multi` (transaction + entries + account updates +
  balance_history_entries + journal_event), and marks the command as
  `:processed`.

  Use this task to measure the **theoretical per-call CPU + I/O cost
  of the processing Multi alone**, with everything else (validation,
  idempotency hashing, queue overhead) stripped away. It's a useful
  baseline for comparing against `load.enqueue + load.drain`, which
  together represent the actual production lifecycle.

  ## Setup

  Drops the perf DB, creates a fresh one, migrates, starts the app.
  Requires `MIX_ENV=perf` and `start_command_queue: false`. This repository
  supplies those database and queue settings in `config/perf.exs`.

  ## Usage

      MIX_ENV=perf mix load.process [concurrency] [seconds]

  ## Arguments

  * `concurrency` — number of concurrent workers (default: 1)
  * `seconds` — duration in seconds (default: 10, accepts floats)

  ## Examples

      MIX_ENV=perf mix load.process
      MIX_ENV=perf mix load.process 10
      MIX_ENV=perf mix load.process 10 30

  ## See also

  * `mix load.enqueue` — **production producer**: validates,
    hashes idempotency, inserts `Command` + `CommandQueueItem`.
  * `mix load.drain` — **production consumer (K=1)**: drains a
    pre-filled queue with one `InstanceProcessor`.

  Production load ≈ `load.enqueue` + `load.drain` running
  concurrently. `load.process` is the synthetic per-call baseline,
  not a model of production traffic.
  """
  use Mix.Task

  @shortdoc "Synthetic per-call baseline (bypasses queue + public API) — :perf env"

  @compile {:no_warn_undefined, DoubleEntryLedger.LoadTesting}

  def run(args) do
    if Mix.env() != :perf do
      Mix.raise(
        "This task can only be run in the :perf environment, please run `MIX_ENV=perf mix load.process`"
      )
    end

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    {concurrency, time} = parse_args(args)

    Code.ensure_compiled!(DoubleEntryLedger.LoadTesting)
    DoubleEntryLedger.LoadTesting.run_load_test(concurrency, time)
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
