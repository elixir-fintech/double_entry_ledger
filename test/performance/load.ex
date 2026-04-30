defmodule DoubleEntryLedger.LoadTesting do
  @moduledoc """
  Load testing for DoubleEntryLedger.

  This module provides functions to perform load testing on the DoubleEntryLedger system.
  It includes functions to create accounts and events, run transactions, and validate balances.
  """

  alias DoubleEntryLedger.{Account, Balance, Instance, Repo}
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.LoadTesting.TelemetryCollector
  @destination_accounts 10
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
      "Running load test with"
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
      "Running enqueue load test with"
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

    IO.puts("#{banner} #{bold(to_string(concurrency))} concurrent transaction(s)")
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

    IO.puts("Operations processed in #{seconds} second(s): #{successful}")
    IO.puts("Operations per second: #{successful / seconds} ops/s")

    TelemetryCollector.print_summary()
    TelemetryCollector.stop()

    validate_instance_balance(instance)
    IO.puts("#{bold("After:")} #{validate_instance_balance(instance)}")
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
