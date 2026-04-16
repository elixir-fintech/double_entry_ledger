defmodule DoubleEntryLedger.LoadTesting.TelemetryCollector do
  @moduledoc """
  Collects telemetry events during a load test run and reports a summary.

  Attaches handlers to the ledger's telemetry events at `start/0`, accumulates
  counts and command processing durations in ETS tables, and produces a summary
  via `summary/0`. Call `stop/0` to detach handlers and tear down tables.

  Durations are stored in native time units (from `:telemetry.span/3`) and
  converted to microseconds in the summary.
  """

  @counters :load_test_counters
  @durations :load_test_durations

  @handlers [
    {"lt-process-stop", [:double_entry_ledger, :command, :process, :stop], :handle_stop},
    {"lt-occ-retry", [:double_entry_ledger, :occ, :retry], :handle_occ_retry},
    {"lt-dead-letter", [:double_entry_ledger, :command, :dead_letter], :handle_dead_letter},
    {"lt-retry", [:double_entry_ledger, :command, :retry], :handle_retry},
    {"lt-trx-created", [:double_entry_ledger, :transaction, :created], :handle_trx_created},
    {"lt-trx-posted", [:double_entry_ledger, :transaction, :posted], :handle_trx_posted},
    {"lt-trx-archived", [:double_entry_ledger, :transaction, :archived], :handle_trx_archived}
  ]

  @doc "Starts collection. Creates ETS tables and attaches handlers."
  @spec start() :: :ok
  def start do
    :ets.new(@counters, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@durations, [:named_table, :public, :duplicate_bag, write_concurrency: true])

    Enum.each(@handlers, fn {id, event, fun} ->
      :telemetry.attach(id, event, Function.capture(__MODULE__, fun, 4), nil)
    end)

    :ok
  end

  @doc "Stops collection. Detaches handlers and deletes ETS tables."
  @spec stop() :: :ok
  def stop do
    Enum.each(@handlers, fn {id, _event, _fun} -> :telemetry.detach(id) end)
    :ets.delete(@counters)
    :ets.delete(@durations)
    :ok
  end

  @doc """
  Returns a summary map with:
    - :total_processed - count of command.process.stop events
    - :p50, :p95, :p99 - latency percentiles in microseconds
    - :min, :max, :mean - latency extremes in microseconds
    - :occ_retries, :retries, :dead_letters - failure counts
    - :trx_created, :trx_posted, :trx_archived - transaction counts
  """
  @spec summary() :: map()
  def summary do
    sorted_durations =
      @durations
      |> :ets.tab2list()
      |> Enum.map(fn {_, dur} -> native_to_microseconds(dur) end)
      |> Enum.sort()

    counters = @counters |> :ets.tab2list() |> Map.new()

    %{
      total_processed: length(sorted_durations),
      p50: percentile(sorted_durations, 50),
      p95: percentile(sorted_durations, 95),
      p99: percentile(sorted_durations, 99),
      min: List.first(sorted_durations) || 0,
      max: List.last(sorted_durations) || 0,
      mean: mean(sorted_durations),
      occ_retries: Map.get(counters, :occ_retries, 0),
      retries: Map.get(counters, :retries, 0),
      dead_letters: Map.get(counters, :dead_letters, 0),
      trx_created: Map.get(counters, :trx_created, 0),
      trx_posted: Map.get(counters, :trx_posted, 0),
      trx_archived: Map.get(counters, :trx_archived, 0)
    }
  end

  @doc "Prints a formatted summary to stdout."
  @spec print_summary() :: :ok
  def print_summary do
    s = summary()

    IO.puts("\n\e[1mTelemetry summary:\e[0m")
    IO.puts("  Commands processed: #{s.total_processed}")

    IO.puts(
      "  Latency (μs):  min=#{s.min}  mean=#{s.mean}  P50=#{s.p50}  P95=#{s.p95}  P99=#{s.p99}  max=#{s.max}"
    )

    IO.puts("  OCC retries: #{s.occ_retries}")
    IO.puts("  Command retries: #{s.retries}")
    IO.puts("  Dead letters: #{s.dead_letters}")

    IO.puts(
      "  Transactions:  created=#{s.trx_created}  posted=#{s.trx_posted}  archived=#{s.trx_archived}"
    )

    :ok
  end

  # Handlers

  @doc false
  def handle_stop(_event, %{duration: duration}, _metadata, _config) do
    :ets.insert(@durations, {:duration, duration})
  end

  @doc false
  def handle_occ_retry(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@counters, :occ_retries, 1, {:occ_retries, 0})
  end

  @doc false
  def handle_dead_letter(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@counters, :dead_letters, 1, {:dead_letters, 0})
  end

  @doc false
  def handle_retry(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@counters, :retries, 1, {:retries, 0})
  end

  @doc false
  def handle_trx_created(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@counters, :trx_created, 1, {:trx_created, 0})
  end

  @doc false
  def handle_trx_posted(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@counters, :trx_posted, 1, {:trx_posted, 0})
  end

  @doc false
  def handle_trx_archived(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@counters, :trx_archived, 1, {:trx_archived, 0})
  end

  # Helpers

  defp percentile([], _p), do: 0

  defp percentile(sorted, p) do
    index = min(trunc(length(sorted) * p / 100), length(sorted) - 1)
    Enum.at(sorted, index)
  end

  defp mean([]), do: 0

  defp mean(values) do
    div(Enum.sum(values), length(values))
  end

  defp native_to_microseconds(native) do
    System.convert_time_unit(native, :native, :microsecond)
  end
end
