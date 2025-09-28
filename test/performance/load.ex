defmodule DoubleEntryLedger.LoadTesting do
  @moduledoc """
  Load testing for DoubleEntryLedger.

  This module provides functions to perform load testing on the DoubleEntryLedger system.
  It includes functions to create accounts and events, run transactions, and validate balances.

  The default run time is 1 second, and the default number of destination accounts is 10 per source account.
  Both defaults can be overridden by setting the @seconds_to_run and @destination_accounts module attributes.
  """

  alias DoubleEntryLedger.{Account, Balance, Instance, Repo}
  alias DoubleEntryLedger.Workers.EventWorker
  alias DoubleEntryLedger.Event.TransactionEventMap
  @destination_accounts 10
  @seconds_to_run 10

  # Function to run a single transaction process

  @doc """
  Runs a load test for a specified number of concurrent transactions.

  ## Parameters

    - concurrency: The number of concurrent transactions to run.

  ## Returns

    - :ok when the load test is completed.
  """
  def run_load_test(concurrency) do
    debit_sum = 100_000
    {:ok, instance} = %Instance{address: "instance:#{System.unique_integer()}"} |> Repo.insert()
    sources = create_debit_sources(concurrency, instance, debit_sum)
    destination_arrays = create_debit_destinations(concurrency, instance)
    # Necessary to balance the ledger
    create_balancing_credit_account(instance, debit_sum * concurrency)

    transaction_lists = create_transaction_lists(sources, destination_arrays)

    IO.puts("Running load test with #{bold(to_string(concurrency))} concurrent transaction(s)")
    IO.puts("#{bold("Before:")} #{validate_instance_balance(instance)}")
    start_time = System.monotonic_time(:millisecond)
    # Run time in milliseconds
    end_time = start_time + 1000 * @seconds_to_run

    # Use a counter to keep track of successful transactions
    successful_transactions =
      run_transactions(concurrency, end_time, 0, instance, 0, transaction_lists)

    IO.puts("Transactions processed in #{@seconds_to_run} second(s): #{successful_transactions}")
    IO.puts("Transactions per second: #{successful_transactions / @seconds_to_run} tps")
    validate_instance_balance(instance)
    IO.puts("#{bold("After:")} #{validate_instance_balance(instance)}")
  end

  # Helper function to run multiple transactions concurrently
  defp run_transactions(concurrency, end_time, counter, instance, index, transaction_lists) do
    # Keep running tasks until the time limit is reached
    if System.monotonic_time(:millisecond) < end_time do
      tasks =
        transaction_lists
        |> Enum.at(index)
        |> Enum.map(&create_task(instance, &1))

      # Await the tasks and increment the counter for successful transactions
      results = Enum.map(tasks, &Task.await/1)

      # Count how many were successful
      successes =
        Enum.count(results, fn
          {:ok, _, _} -> true
          _ -> false
        end)

      # Calculate the next index to use or loop back to the beginning
      new_index =
        if index == @destination_accounts - 1 do
          0
        else
          index + 1
        end

      # Recur with updated time and count
      run_transactions(
        concurrency,
        end_time,
        counter + successes,
        instance,
        new_index,
        transaction_lists
      )
    else
      # Return the total count after time runs out
      counter
    end
  end

  # insert a single event and then create the transaction from it
  defp run_transaction(instance, params) do
    {:ok, event_map} =
      TransactionEventMap.create(%{
        action: :create_transaction,
        status: :pending,
        source: "source",
        source_idempk: Ecto.UUID.generate(),
        payload: params,
        instance_address: instance.address
      })

    EventWorker.process_new_event(event_map)
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

  # create a single async task to run an event/transaction
  defp create_task(instance, trx_params) do
    Task.async(fn ->
      run_transaction(instance, trx_params)
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
