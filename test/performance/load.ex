defmodule DoubleEntryLedger.LoadTesting do
  @moduledoc """
  Load-testing harness for DoubleEntryLedger.

  Three orthogonal entry points, surfaced as mix tasks:

    * `run_enqueue_load_test/2` — **production producer**
      (`mix load.enqueue`). Sliding window of N concurrent workers
      calling `CommandApi.create_from_params/1` — the same public
      API real production callers use. Validates params, hashes
      idempotency, inserts `Command` + `CommandQueueItem`. No
      processing.

    * `run_drain_load_test/1` — **production consumer (K=1)**
      (`mix load.drain`). Pre-fills the queue with N commands via
      the producer path, then starts a single `InstanceProcessor`
      and times the drain. Goes through
      `CommandWorker.process_command_with_id/2` — the real
      consumer code path.

    * `run_load_test/2` — **synthetic in-process baseline**
      (`mix load.process`). Sliding window of N concurrent workers
      calling `CommandWorker.process_new_command/1` directly.
      Bypasses both the queue *and* the public API
      (`create_from_params`/`process_from_params`). Useful as a
      per-call ceiling baseline; **not a model of production
      traffic.**

  Production load is modelled by `enqueue` + `drain` running
  concurrently. `load.process` is a synthetic per-call baseline,
  not a path real callers hit.

  All three share the same instance/account fixtures. The
  enqueue/process tests share the sliding-window driver
  (`run_with_driver/4`); drain has its own pre-fill + monitor
  shape. Latencies are aggregated by
  `LoadTesting.TelemetryCollector`.
  """

  alias DoubleEntryLedger.{Account, Balance, Instance, Repo}
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.CommandQueue.InstanceProcessor
  alias DoubleEntryLedger.LoadTesting.TelemetryCollector
  @destination_accounts 10
  @drain_prefill_concurrency 10
  # Function to run a single transaction process

  @doc """
  Runs a load test that exercises the **full processing path**:
  `CommandWorker.process_new_command/1` (validate → command insert →
  transaction insert → entries/accounts/BHE/journal_event → mark
  processed). This bypasses the queue and processes synchronously.

  ## Parameters

    - concurrency: The number of concurrent transactions to run.
    - seconds: How long to run.
  """
  def run_load_test(concurrency, seconds) do
    run_with_driver(
      concurrency,
      seconds,
      &run_transaction/2,
      "load.process — full processing,"
    )
  end

  @doc """
  Runs a load test for the **enqueue-only** path:
  `CommandApi.create_from_params/1`, which validates the payload shape,
  hashes the idempotency key, and inserts the `Command` +
  `CommandQueueItem` rows. Subsequent processing through the queue is
  not measured here. The queue is configured off via
  `start_command_queue: false` in `config/perf.exs`, so claimed work
  doesn't drain in the background.

  This isolates the throughput cost of just *getting commands into the
  queue* — i.e. the production producer path.

  ## Parameters

    - concurrency: The number of concurrent enqueue calls.
    - seconds: How long to run.
  """
  def run_enqueue_load_test(concurrency, seconds) do
    run_with_driver(
      concurrency,
      seconds,
      &enqueue_command/2,
      "load.enqueue — producer only,"
    )
  end

  # Shared driver — sets up the instance + accounts, spins up the
  # sliding-window workers, and reports throughput. The `worker_fn`
  # callback decides what each iteration of work does; it must accept
  # `(instance, params)` and return any tuple starting with `:ok` for
  # success.
  defp run_with_driver(concurrency, seconds, worker_fn, banner) do
    debit_sum = trunc(100_000 * seconds)
    {:ok, instance} = %Instance{address: "instance:#{System.unique_integer()}"} |> Repo.insert()
    sources = create_debit_sources(concurrency, instance, debit_sum)
    destination_arrays = create_debit_destinations(concurrency, instance)
    # Necessary to balance the ledger
    create_balancing_credit_account(instance, debit_sum * concurrency)

    transaction_lists = create_transaction_lists(sources, destination_arrays)

    IO.puts(
      "#{bold(banner)} concurrency=#{bold(to_string(concurrency))} " <>
        "duration=#{bold(to_string(seconds))}s"
    )

    IO.puts("#{bold("Before:")} #{validate_instance_balance(instance)}")

    TelemetryCollector.start()

    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + 1000 * seconds

    # https://blog.appsignal.com/2022/04/26/using-profiling-in-elixir-to-improve-performance.html
    # To profile: uncomment the four `:eprof.*` lines (and the
    # `Application.ensure_all_started/1` call). `mix.exs` keeps `:tools` in
    # `extra_applications` for the `:perf` env so `:eprof` is available.
    # Pass `Process.list()` to the rootset so workers spawn_link'd below are
    # picked up — `:eprof.profile(fun)` and `start_profiling([self()])` only
    # capture the driver and miss the actual transaction work.
    # Application.ensure_all_started(:tools)
    # {:ok, _} = :eprof.start()
    # :eprof.start_profiling(Process.list())

    # Sliding-window driver: holds exactly `concurrency` workers in flight at all
    # times until end_time. Each worker is a long-lived process that pulls its
    # next params from `transaction_lists` based on its worker_id and iteration,
    # so there is no central queue and no per-round barrier.
    successful =
      run_sliding_window(concurrency, end_time, instance, transaction_lists, worker_fn)

    # :eprof.stop_profiling()
    # :eprof.analyze()

    IO.puts(
      "Operations: #{bold(to_string(successful))} in #{seconds}s — " <>
        "#{bold(:erlang.float_to_binary(successful / seconds, decimals: 1))} ops/s"
    )

    TelemetryCollector.print_summary()
    TelemetryCollector.stop()

    validate_instance_balance(instance)
    IO.puts("#{bold("After:")} #{validate_instance_balance(instance)}")
  end

  @doc """
  Runs a queue-drain load test for the **consumer-only** path.

  Pre-fills the queue with `prefill_count` pending commands via
  `CommandApi.create_from_params/1` (the producer path), then starts a
  single `InstanceProcessor` and times how long it takes to drain
  every command. The `InstanceProcessor` exits `:normal` when the
  queue is empty, which is the signal we use to stop the clock.

  Pre-fill is parallelized across `@drain_prefill_concurrency` workers
  but is **not** part of the measurement — only drain throughput is
  reported. Drain throughput here is the K=1 single-instance,
  single-processor consumer ceiling: the rate at which one
  `InstanceProcessor` can claim, process, and mark commands processed
  one at a time.

  Requires `start_command_queue: false` in `config/perf.exs` (the
  default for `:perf`) so the queue's normal supervision isn't
  competing for the same instance.

  ## Parameters

    - prefill_count: Number of commands to enqueue before draining.
      Bigger means more steady-state, longer test. Default suggestion: 10000.
  """
  def run_drain_load_test(prefill_count) when is_integer(prefill_count) and prefill_count > 0 do
    debit_sum = max(trunc(100_000 * prefill_count / 10), 1_000_000)
    pool_size = min(10, prefill_count)

    {:ok, instance} = %Instance{address: "instance:#{System.unique_integer()}"} |> Repo.insert()
    sources = create_debit_sources(pool_size, instance, debit_sum)
    destination_arrays = create_debit_destinations(pool_size, instance)
    create_balancing_credit_account(instance, debit_sum * pool_size)

    transaction_lists = create_transaction_lists(sources, destination_arrays)
    flat_params = List.flatten(transaction_lists)
    flat_count = length(flat_params)

    IO.puts(
      "#{bold("load.drain")} — consumer only, K=1: " <>
        "pre-fill #{bold(to_string(prefill_count))} commands, " <>
        "then drain via a single InstanceProcessor"
    )

    IO.puts("#{bold("Before:")} #{validate_instance_balance(instance)}")

    # ── Pre-fill phase (not measured) ───────────────────────────────────
    prefill_start = System.monotonic_time(:millisecond)

    1..prefill_count
    |> Task.async_stream(
      fn i ->
        params = Enum.at(flat_params, rem(i - 1, flat_count))
        enqueue_command(instance, params)
      end,
      max_concurrency: @drain_prefill_concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    prefill_elapsed = (System.monotonic_time(:millisecond) - prefill_start) / 1000.0

    IO.puts(
      "Pre-fill: #{bold(to_string(prefill_count))} commands in " <>
        "#{Float.round(prefill_elapsed, 2)}s — " <>
        "#{bold(:erlang.float_to_binary(prefill_count / prefill_elapsed, decimals: 1))} ops/s " <>
        "(not measured)"
    )

    # ── Drain phase (measured) ──────────────────────────────────────────
    # The InstanceProcessor uses a Registry-keyed via_tuple. Start the
    # Registry locally for the test if the queue's own supervision isn't
    # running (which is the perf-env default).
    ensure_command_queue_registry_started()

    TelemetryCollector.start()

    drain_start = System.monotonic_time(:millisecond)
    {:ok, processor_pid} = InstanceProcessor.start_link(instance_id: instance.id)
    ref = Process.monitor(processor_pid)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        raise "InstanceProcessor crashed: #{inspect(reason)}"
    end

    drain_elapsed = (System.monotonic_time(:millisecond) - drain_start) / 1000.0
    drain_tps = prefill_count / drain_elapsed

    IO.puts(
      "Drain: #{bold(to_string(prefill_count))} commands in " <>
        "#{Float.round(drain_elapsed, 2)}s — " <>
        "#{bold(:erlang.float_to_binary(drain_tps, decimals: 1))} tps"
    )

    TelemetryCollector.print_summary()
    TelemetryCollector.stop()

    IO.puts("#{bold("After:")} #{validate_instance_balance(instance)}")
  end

  defp ensure_command_queue_registry_started do
    case Registry.start_link(keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # Sliding-window orchestrator. Spawns `concurrency` worker processes that each
  # loop until end_time. Each worker reports its total success count to the
  # caller exactly once, on exit. No barrier, no central work queue.
  defp run_sliding_window(concurrency, end_time, instance, transaction_lists, worker_fn) do
    parent = self()
    num_rounds = length(transaction_lists)

    workers =
      Enum.map(0..(concurrency - 1), fn worker_id ->
        spawn_link(fn ->
          worker_loop(
            parent,
            instance,
            transaction_lists,
            num_rounds,
            worker_id,
            0,
            0,
            end_time,
            worker_fn
          )
        end)
      end)

    collect_results(MapSet.new(workers), 0)
  end

  # Each worker is bound to a fixed source account (its worker_id). Across
  # iterations it cycles through the @destination_accounts destination accounts
  # for that source, mirroring the slot the original barrier-based driver would
  # have placed it in. `worker_fn` is the per-iteration unit of work.
  defp worker_loop(
         parent,
         instance,
         transaction_lists,
         num_rounds,
         worker_id,
         iter,
         success_count,
         end_time,
         worker_fn
       ) do
    if System.monotonic_time(:millisecond) >= end_time do
      send(parent, {:worker_done, self(), success_count})
    else
      params =
        transaction_lists
        |> Enum.at(rem(iter, num_rounds))
        |> Enum.at(worker_id)

      delta =
        case worker_fn.(instance, params) do
          {:ok, _, _} -> 1
          {:ok, _} -> 1
          _ -> 0
        end

      worker_loop(
        parent,
        instance,
        transaction_lists,
        num_rounds,
        worker_id,
        iter + 1,
        success_count + delta,
        end_time,
        worker_fn
      )
    end
  end

  defp collect_results(pending, total) do
    if MapSet.size(pending) == 0 do
      total
    else
      receive do
        {:worker_done, pid, count} ->
          collect_results(MapSet.delete(pending, pid), total + count)
      end
    end
  end

  # insert a single event and then create the transaction from it
  defp run_transaction(instance, params) do
    {:ok, command_map} =
      TransactionCommandMap.create(%{
        action: :create_transaction,
        status: :pending,
        source: "source",
        source_idempk: Ecto.UUID.generate(),
        payload: params,
        instance_address: instance.address
      })

    CommandWorker.process_new_command(command_map)
  end

  # Enqueue-only path: validate params, hash idempotency, insert
  # `Command` + `CommandQueueItem`. No transaction processing.
  # Wraps the call in a synthetic `command.process` telemetry span
  # so `TelemetryCollector` sees the latency without needing changes.
  defp enqueue_command(instance, params) do
    :telemetry.span(
      [:double_entry_ledger, :command, :process],
      %{},
      fn ->
        result =
          CommandApi.create_from_params(%{
            "action" => "create_transaction",
            "source" => "source",
            "source_idempk" => Ecto.UUID.generate(),
            "instance_address" => instance.address,
            "payload" => Map.put(params, :status, :posted)
          })

        {result, %{}}
      end
    )
  end

  # create as many source debit accounts as concurrent transactions to minimize contention
  # The accounts are created with a balance of 100 EUR
  defp create_debit_sources(concurrency, instance, debit_sum) do
    1..concurrency
    |> Enum.map(fn _ ->
      %Account{
        instance_id: instance.id,
        address: "source:#{:rand.uniform(1_000_000)}",
        type: :asset,
        normal_balance: :debit,
        posted: %Balance{amount: debit_sum, debit: debit_sum, credit: 0},
        available: debit_sum,
        currency: :EUR
      }
      |> Repo.insert!()
    end)
  end

  # create @destination_accounts number of debit destination accounts for each source account
  defp create_debit_destinations(concurrency, instance) do
    1..concurrency
    |> Enum.map(fn _ ->
      1..@destination_accounts
      |> Enum.map(fn _ ->
        %Account{
          instance_id: instance.id,
          address: "destination:#{:rand.uniform(1_000_000)}",
          type: :asset,
          normal_balance: :debit,
          posted: %Balance{amount: 0, debit: 0, credit: 0},
          available: 0,
          currency: :EUR
        }
        |> Repo.insert!()
      end)
    end)
  end

  # create a single credit account to balance the ledger
  # The account is created with a balance of 100 EUR * concurrency
  defp create_balancing_credit_account(instance, credit_sum) do
    %Account{
      instance_id: instance.id,
      address: "balancing:credit:account",
      type: :liability,
      normal_balance: :credit,
      posted: %Balance{amount: credit_sum, debit: 0, credit: credit_sum},
      available: credit_sum,
      currency: :EUR
    }
    |> Repo.insert()
  end

  # create a list of transactions for each source account to each destination account per concurrency
  # this is a simple transfer of 10 EUR from source to destination
  defp create_transaction_lists(sources, destination_arrays) do
    destination_arrays
    |> Enum.zip()
    |> Enum.map(fn sub_list ->
      Enum.zip(sources, Tuple.to_list(sub_list))
      |> Enum.map(fn {source, destination} ->
        %{
          status: :posted,
          entries: [
            %{currency: :EUR, amount: -10, account_address: source.address},
            %{currency: :EUR, amount: 10, account_address: destination.address}
          ]
        }
      end)
    end)
  end

  # Validate the instance balances and make sure the ledger balances
  defp validate_instance_balance(instance) do
    # Validate the instance balance
    case Instance.validate_account_balances(instance) do
      {:ok, value} -> "Account balances are equal #{inspect(value)}"
      {:error, error} -> raise("Account balances are not equal: #{error}")
    end
  end

  # Helper function to print bold text in the console
  defp bold(text) do
    "\e[1m#{text}\e[0m"
  end
end
