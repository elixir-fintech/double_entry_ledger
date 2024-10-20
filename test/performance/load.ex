defmodule DoubleEntryLedger.LoadTesting do
  @moduledoc """
  Load testing for DoubleEntryLedger
  """
  alias DoubleEntryLedger.{Account, Balance, Instance, EventStore, EventProcessor, Repo}

  # Function to run a single transaction process
  defp run_transaction(instance, params ) do
    # Simulate a transaction with random data (adjust params accordingly)
    {:ok, event} = EventStore.insert_event(%{
      action: :create,
      status: :pending,
      source: "source",
      source_id: Ecto.UUID.generate(),
      transaction_data: params, instance_id: instance.id})
    EventProcessor.process_event(event)
  end

  # Function to run load test for 1 second
  def run_load_test(concurrency) do
    {:ok, instance} = %Instance{} |> Repo.insert()
    {:ok, account_1} = %Account{instance_id: instance.id, type: :debit, posted: %Balance{amount: 100_000, debit: 100_000, credit: 0}, available: 100_000} |> Repo.insert()
    {:ok, account_2} = %Account{instance_id: instance.id, type: :debit, posted: %Balance{amount: 0, debit: 0, credit: 0}} |> Repo.insert()
    {:ok, _account_3} = %Account{instance_id: instance.id, type: :credit, posted: %Balance{amount: 100_000, debit: 0, credit: 100_000}, available: 100_000} |> Repo.insert()
    trx_params = %{status: :posted, entries: [
      %{currency: :EUR, amount: -10, account_id: account_1.id},
      %{currency: :EUR, amount: 10, account_id: account_2.id}]
    }
    case Instance.validate_account_balances(instance) do
      {:ok, value} -> IO.puts("Account balances are equal #{inspect(value)}")
      {:error, error} -> raise("Account balances are not equal: #{error}")
    end
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + 1000  # Run for 1 second (1000 milliseconds)

    # Use a counter to keep track of successful transactions
    successful_transactions = run_transactions(concurrency, end_time, 0, [instance, trx_params])
    a1 = Repo.get(Account, account_1.id)
    a2 = Repo.get(Account, account_2.id)
    IO.puts("Transactions processed in 1 second: #{successful_transactions}")
    IO.puts("Account 1 balance: #{a1.posted.amount}")
    IO.puts("Account 2 balance: #{a2.posted.amount}")

    case Instance.validate_account_balances(instance) do
      {:ok, value} -> IO.puts("Account balances are equal #{inspect(value)}")
      {:error, error} -> raise("Account balances are not equal: #{error}")
    end
  end

  # Helper function to run multiple transactions concurrently
  defp run_transactions(concurrency, end_time, counter, [i, trx_params] = args) do
    # Keep running tasks until the time limit is reached
    if System.monotonic_time(:millisecond) < end_time do
      tasks =
        1..concurrency
        |> Enum.map(fn _ ->
          Task.async(fn -> run_transaction(i, trx_params) end)
        end)

      # Await the tasks and increment the counter for successful transactions
      results = Enum.map(tasks, &Task.await/1)

      # Count how many were successful
      successes = Enum.count(results, fn
        {:ok, _, _} -> true
        _ -> false
      end)

      # Recur with updated time and count
      run_transactions(concurrency, end_time, counter + successes, args)
    else
      # Return the total count after time runs out
      counter
    end
  end
end
