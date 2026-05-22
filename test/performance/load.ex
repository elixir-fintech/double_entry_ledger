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

  @doc """
  Mixed-workload drain test for B7: pre-fills `create_count` :pending
  creates and `update_count` updates targeting those creates, then
  drains. The drain proceeds in two phases so updates only enqueue
  after their target creates have committed — there's no same-batch
  create/update collision noise to obscure the throughput number.

  Phase timing:
    1. Prefill all creates (deterministic source_idempk per create).
    2. **Drain creates** — not measured.
    3. Prefill all updates (one update per create, random new_status).
    4. **Drain updates** — MEASURED.

  The reported tps is `update_count / phase4_elapsed`. Use a 1:1 ratio
  (`create_count == update_count`) to model the B7 "50/50 mixed
  corpus" workload.

  ## Parameters

    - create_count: number of :pending creates to pre-fill in phase 1.
    - update_count: number of updates to enqueue in phase 3
      (must be ≤ create_count so every update has a target).
  """
  def run_mixed_drain_load_test(create_count, update_count)
      when is_integer(create_count) and create_count > 0 and
             is_integer(update_count) and update_count > 0 and
             update_count <= create_count do
    debit_sum = max(trunc(100_000 * create_count / 10), 1_000_000)
    pool_size = min(10, create_count)

    {:ok, instance} =
      %Instance{address: "instance:mixed:#{System.unique_integer()}"} |> Repo.insert()

    sources = create_debit_sources(pool_size, instance, debit_sum)
    destination_arrays = create_debit_destinations(pool_size, instance)
    create_balancing_credit_account(instance, debit_sum * pool_size)

    transaction_lists = create_transaction_lists(sources, destination_arrays)
    flat_params = List.flatten(transaction_lists)
    flat_count = length(flat_params)

    IO.puts(
      "#{bold("load.mixed_drain")} — K=1: " <>
        "#{bold(to_string(create_count))} :pending creates + " <>
        "#{bold(to_string(update_count))} updates"
    )

    IO.puts("#{bold("Before:")} #{validate_instance_balance(instance)}")

    # Per-create idempotency keys; the updates reuse these.
    create_idempks =
      Enum.map(1..create_count, fn i -> {i, "create:#{i}"} end)

    # ── Phase 1: prefill creates ────────────────────────────────────────
    IO.puts("Phase 1: prefilling #{create_count} :pending creates…")
    prefill_start = System.monotonic_time(:millisecond)

    create_idempks
    |> Task.async_stream(
      fn {i, idempk} ->
        params = Enum.at(flat_params, rem(i - 1, flat_count))
        enqueue_create_with(instance, idempk, :pending, params)
      end,
      max_concurrency: @drain_prefill_concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    prefill_elapsed = (System.monotonic_time(:millisecond) - prefill_start) / 1000.0
    IO.puts("  Prefill creates: #{Float.round(prefill_elapsed, 2)}s (not measured)")

    # ── Phase 2: drain creates (not measured) ───────────────────────────
    IO.puts("Phase 2: draining creates (not measured)…")
    ensure_command_queue_registry_started()
    drain_phase(instance)

    # ── Phase 3: prefill updates ────────────────────────────────────────
    # Each update targets a randomly chosen new status. Payload entries
    # mirror the create's amount/accounts so non-archived transitions
    # produce sensible deltas.
    IO.puts("Phase 3: prefilling #{update_count} updates…")
    update_prefill_start = System.monotonic_time(:millisecond)

    create_idempks
    |> Enum.take(update_count)
    |> Task.async_stream(
      fn {i, source_idempk} ->
        params = Enum.at(flat_params, rem(i - 1, flat_count))
        new_status = Enum.random([:posted, :pending, :archived])
        enqueue_update_with(instance, source_idempk, "upd:#{i}", new_status, params)
      end,
      max_concurrency: @drain_prefill_concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    update_prefill_elapsed =
      (System.monotonic_time(:millisecond) - update_prefill_start) / 1000.0

    IO.puts("  Prefill updates: #{Float.round(update_prefill_elapsed, 2)}s (not measured)")

    # ── Phase 4: drain updates (MEASURED) ───────────────────────────────
    IO.puts("Phase 4: draining updates (measured)…")
    TelemetryCollector.start()

    drain_start = System.monotonic_time(:millisecond)
    drain_phase(instance)
    drain_elapsed = (System.monotonic_time(:millisecond) - drain_start) / 1000.0
    drain_tps = update_count / drain_elapsed

    IO.puts(
      "Drain updates: #{bold(to_string(update_count))} updates in " <>
        "#{Float.round(drain_elapsed, 2)}s — " <>
        "#{bold(:erlang.float_to_binary(drain_tps, decimals: 1))} tps"
    )

    TelemetryCollector.print_summary()
    TelemetryCollector.stop()

    IO.puts("#{bold("After:")} #{validate_instance_balance(instance)}")
  end

  defp drain_phase(instance) do
    {:ok, processor_pid} = InstanceProcessor.start_link(instance_id: instance.id)
    ref = Process.monitor(processor_pid)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        raise "InstanceProcessor crashed: #{inspect(reason)}"
    end
  end

  defp ensure_command_queue_registry_started do
    case Registry.start_link(keys: :unique, name: DoubleEntryLedger.CommandQueue.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Runs `n_instances` `InstanceProcessor`s in parallel, each draining
  `prefill_per_instance` commands. Reports per-instance + aggregate
  tps to validate the horizontal-scaling claim.

  Separate instances have non-overlapping accounts and disjoint queue
  partitions, so M `InstanceProcessor`s on M instances should give
  roughly M × per-instance-tps aggregate throughput. This script
  measures that.

  Setup (not measured): creates `n_instances` instances with
  deterministic addresses (`"instance:multi:<i>"`), each with its
  own pool of source / destination / balancing accounts, then
  pre-fills `prefill_per_instance` commands per instance via
  `Task.async_stream` (parallel across instances and across
  commands).

  Drain (measured): one `InstanceProcessor` per instance is started
  in parallel from per-instance Task drivers; each driver records its
  own start / end timestamps. Aggregate wall time is `max(end) -
  min(start)`. Aggregate tps is `(n_instances *
  prefill_per_instance) / aggregate_wall_time`.

  ## TelemetryCollector choice

  Started once at the top of the drain phase and stopped at the end
  — so latency stats (min/mean/P50/P95/P99/max) are aggregated
  across all instances into one combined histogram. This matches
  what we want to know: "does the per-command latency distribution
  shift as N grows?"

  ## Parameters

    - n_instances: number of parallel `InstanceProcessor`s / instances.
    - prefill_per_instance: number of pre-filled commands per instance.
  """
  @spec run_multi_drain_load_test(pos_integer(), pos_integer()) :: :ok
  def run_multi_drain_load_test(n_instances, prefill_per_instance)
      when is_integer(n_instances) and n_instances > 0 and
             is_integer(prefill_per_instance) and prefill_per_instance > 0 do
    debit_sum = max(trunc(100_000 * prefill_per_instance / 10), 1_000_000)
    pool_size = min(10, prefill_per_instance)
    total_commands = n_instances * prefill_per_instance

    IO.puts(
      "#{bold("load.multi_drain")} — consumer scaling, K=#{bold(to_string(n_instances))}: " <>
        "pre-fill #{bold(to_string(prefill_per_instance))} commands/instance, " <>
        "then drain via #{bold(to_string(n_instances))} parallel InstanceProcessors"
    )

    # ── Setup phase (not measured) ──────────────────────────────────────
    setup_start = System.monotonic_time(:millisecond)

    instances =
      1..n_instances
      |> Enum.map(fn i ->
        {:ok, instance} =
          %Instance{address: "instance:multi:#{i}:#{System.unique_integer([:positive])}"}
          |> Repo.insert()

        sources = create_multi_debit_sources(pool_size, instance, debit_sum, i)
        destination_arrays = create_multi_debit_destinations(pool_size, instance, i)
        create_balancing_credit_account(instance, debit_sum * pool_size)

        transaction_lists = create_transaction_lists(sources, destination_arrays)
        flat_params = List.flatten(transaction_lists)

        %{instance: instance, flat_params: flat_params, flat_count: length(flat_params)}
      end)

    Enum.each(instances, fn %{instance: instance} ->
      IO.puts("#{bold("Before [#{instance.address}]:")} #{validate_instance_balance(instance)}")
    end)

    # Pre-fill in parallel across all (instance, command) pairs.
    pairs =
      for %{instance: inst, flat_params: fp, flat_count: fc} <- instances,
          i <- 1..prefill_per_instance,
          do: {inst, Enum.at(fp, rem(i - 1, fc))}

    pairs
    |> Task.async_stream(
      fn {instance, params} -> enqueue_command(instance, params) end,
      max_concurrency: @drain_prefill_concurrency * n_instances,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    setup_elapsed = (System.monotonic_time(:millisecond) - setup_start) / 1000.0

    IO.puts(
      "Pre-fill: #{bold(to_string(total_commands))} commands across " <>
        "#{bold(to_string(n_instances))} instances in " <>
        "#{Float.round(setup_elapsed, 2)}s — " <>
        "#{bold(:erlang.float_to_binary(total_commands / setup_elapsed, decimals: 1))} ops/s " <>
        "(not measured)"
    )

    # ── Drain phase (measured) ──────────────────────────────────────────
    ensure_command_queue_registry_started()

    TelemetryCollector.start()

    overall_start = System.monotonic_time(:millisecond)

    per_instance_results =
      instances
      |> Task.async_stream(
        fn %{instance: instance} -> drive_one_processor(instance) end,
        max_concurrency: n_instances,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} -> result end)

    overall_elapsed = (System.monotonic_time(:millisecond) - overall_start) / 1000.0

    # Per-instance wall times use each driver's own start/end stamps;
    # aggregate wall time is max(end) - min(start) across drivers,
    # which closely matches `overall_elapsed` but is robust to
    # Task.async_stream scheduling jitter.
    min_start = per_instance_results |> Enum.map(& &1.start_ms) |> Enum.min()
    max_end = per_instance_results |> Enum.map(& &1.end_ms) |> Enum.max()
    aggregate_wall = (max_end - min_start) / 1000.0
    aggregate_tps = total_commands / aggregate_wall

    IO.puts("\n#{bold("Per-instance drain:")}")

    Enum.each(per_instance_results, fn r ->
      tps = prefill_per_instance / r.elapsed_s

      IO.puts(
        "  [#{r.address}] #{prefill_per_instance} cmds in " <>
          "#{Float.round(r.elapsed_s, 2)}s — " <>
          "#{bold(:erlang.float_to_binary(tps, decimals: 1))} tps"
      )
    end)

    IO.puts(
      "\n#{bold("Aggregate drain:")} #{total_commands} commands in " <>
        "#{Float.round(aggregate_wall, 2)}s — " <>
        "#{bold(:erlang.float_to_binary(aggregate_tps, decimals: 1))} tps " <>
        "(overall_elapsed=#{Float.round(overall_elapsed, 2)}s)"
    )

    # Scaling efficiency. The "baseline" is the K=1 per-instance tps
    # from prior measurements on this machine (≈881 tps with
    # BATCH=on BATCH_SIZE=64). At N instances we expect aggregate ≈ N
    # × baseline; efficiency is how close we got.
    baseline_per_instance = 881.0
    expected_aggregate = n_instances * baseline_per_instance
    efficiency_vs_baseline = aggregate_tps / expected_aggregate

    IO.puts(
      "Scaling: aggregate_tps / (N × baseline #{baseline_per_instance}) = " <>
        "#{Float.round(efficiency_vs_baseline, 3)} " <>
        "(1.0 = perfect linear scaling vs prior K=1 measurement)"
    )

    TelemetryCollector.print_summary()
    TelemetryCollector.stop()

    Enum.each(instances, fn %{instance: instance} ->
      IO.puts("#{bold("After [#{instance.address}]:")} #{validate_instance_balance(instance)}")
    end)

    :ok
  end

  # Drives one InstanceProcessor end-to-end. Captures its own
  # start/end monotonic timestamps so per-instance tps is accurate
  # regardless of when Task.async_stream actually schedules this
  # closure.
  defp drive_one_processor(instance) do
    start_ms = System.monotonic_time(:millisecond)
    {:ok, processor_pid} = InstanceProcessor.start_link(instance_id: instance.id)
    ref = Process.monitor(processor_pid)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        raise "InstanceProcessor for #{instance.address} crashed: #{inspect(reason)}"
    end

    end_ms = System.monotonic_time(:millisecond)

    %{
      address: instance.address,
      start_ms: start_ms,
      end_ms: end_ms,
      elapsed_s: (end_ms - start_ms) / 1000.0
    }
  end

  # Same shape as create_debit_sources/3 but uses deterministic
  # addresses scoped to a specific multi-drain instance index, so
  # account addresses don't collide and are disjoint across the
  # n_instances under test.
  defp create_multi_debit_sources(pool_size, instance, debit_sum, instance_idx) do
    1..pool_size
    |> Enum.map(fn j ->
      %Account{
        instance_id: instance.id,
        address: "instance:multi:#{instance_idx}:source:#{j}",
        type: :asset,
        normal_balance: :debit,
        posted: %Balance{amount: debit_sum, debit: debit_sum, credit: 0},
        available: debit_sum,
        currency: :EUR
      }
      |> Repo.insert!()
    end)
  end

  defp create_multi_debit_destinations(pool_size, instance, instance_idx) do
    1..pool_size
    |> Enum.map(fn j ->
      1..@destination_accounts
      |> Enum.map(fn k ->
        %Account{
          instance_id: instance.id,
          address: "instance:multi:#{instance_idx}:destination:#{j}:#{k}",
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
    enqueue_via_command_api(%{
      "action" => "create_transaction",
      "source" => "source",
      "source_idempk" => Ecto.UUID.generate(),
      "instance_address" => instance.address,
      "payload" => Map.put(params, :status, :posted)
    })
  end

  # Create command with a caller-supplied source_idempk and status —
  # used by `run_mixed_drain_load_test/2` so the updates phase can
  # reference each create by its deterministic key.
  defp enqueue_create_with(instance, source_idempk, status, params) do
    enqueue_via_command_api(%{
      "action" => "create_transaction",
      "source" => "source",
      "source_idempk" => source_idempk,
      "instance_address" => instance.address,
      "payload" => Map.put(params, :status, status)
    })
  end

  # Update command targeting the create at `source_idempk`. The
  # update_idempk uniquifies the update itself.
  defp enqueue_update_with(instance, source_idempk, update_idempk, status, params) do
    enqueue_via_command_api(%{
      "action" => "update_transaction",
      "source" => "source",
      "source_idempk" => source_idempk,
      "update_idempk" => update_idempk,
      "instance_address" => instance.address,
      "payload" => Map.put(params, :status, status)
    })
  end

  # Shared telemetry-wrapped entry point. Callers build the string-keyed
  # params map matching `CommandApi.create_from_params/1`'s contract.
  defp enqueue_via_command_api(params) do
    :telemetry.span(
      [:double_entry_ledger, :command, :process],
      %{},
      fn ->
        result = CommandApi.create_from_params(params)
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
