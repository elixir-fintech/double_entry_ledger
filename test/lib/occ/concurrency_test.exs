defmodule DoubleEntryLedger.Occ.ConcurrencyTest do
  @moduledoc """
  Smoke test for concurrent transaction processing.

  Verifies that two concurrent transactions touching the same account
  both succeed without data corruption. Note: the SQL sandbox serializes
  queries on a shared connection, so true OCC retry (StaleEntryError)
  may not be triggered here. OCC retry logic is tested explicitly in
  the command worker tests via mocked StaleEntryError.
  """
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures

  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.Repo
  alias DoubleEntryLedger.Stores.AccountStore

  setup [:create_instance, :create_accounts]

  defp process_transaction(instance_address, from_address, to_address, amount, idempk) do
    CommandApi.process_from_params(
      %{
        "instance_address" => instance_address,
        "action" => "create_transaction",
        "source" => "concurrency_test",
        "source_idempk" => idempk,
        "payload" => %{
          "status" => "posted",
          "entries" => [
            %{
              "account_address" => from_address,
              "amount" => amount,
              "currency" => "EUR"
            },
            %{
              "account_address" => to_address,
              "amount" => amount,
              "currency" => "EUR"
            }
          ]
        }
      },
      on_error: :fail
    )
  end

  test "concurrent transactions on same account both succeed without corruption", %{
    instance: inst,
    accounts: [a1, a2 | _]
  } do
    a3 = account_fixture(instance_id: inst.id, type: :liability, normal_balance: :credit)

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    task1 =
      Task.async(fn ->
        process_transaction(inst.address, a1.address, a2.address, 50, "concurrent_1")
      end)

    task2 =
      Task.async(fn ->
        process_transaction(inst.address, a1.address, a3.address, 50, "concurrent_2")
      end)

    result1 = Task.await(task1, 10_000)
    result2 = Task.await(task2, 10_000)

    assert {:ok, _trx1, _cmd1} = result1
    assert {:ok, _trx2, _cmd2} = result2

    # Verify final balance is consistent: a1 posted debit should be 100 (50 + 50)
    {:ok, [final_a1]} = AccountStore.get_accounts_by_instance_id(inst.id, [a1.address])
    assert final_a1.posted.amount == 100
  end
end
