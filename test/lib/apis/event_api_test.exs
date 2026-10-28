defmodule DoubleEntryLedger.Apis.EventApiTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase
  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.Command.AccountCommandMap
  alias DoubleEntryLedger.Repo
  alias DoubleEntryLedger.Stores.{AccountStore, InstanceStore}
  doctest CommandApi

  describe "process_from_params/2 rejections" do
    setup do
      {:ok, instance} = InstanceStore.create(%{address: "api:test"})
      account = %{type: :asset, currency: :EUR}

      {:ok, _} =
        AccountStore.create(instance.address, Map.put(account, :address, "cash:eur"), "cash")

      {:ok, _} =
        AccountStore.create(instance.address, Map.put(account, :address, "bank:eur"), "bank")

      {:ok, _} =
        AccountStore.create(
          instance.address,
          Map.merge(account, %{address: "card:eur", negative_limit: 50}),
          "card"
        )

      %{instance: instance}
    end

    test "an archived create returns a status error in retry mode", %{instance: instance} do
      params = transaction_params(instance, "archived", "bank:eur", "cash:eur", 100)

      assert {:error, changeset} = CommandApi.process_from_params(params)

      assert %{
               payload: %{
                 status: [
                   "cannot create :archived transactions, must be transitioned from :pending"
                 ]
               }
             } = errors_on(changeset)
    end

    test "an archived create returns a status error in fail mode", %{instance: instance} do
      params = transaction_params(instance, "archived", "bank:eur", "cash:eur", 100)

      assert {:error, changeset} = CommandApi.process_from_params(params, on_error: :fail)

      assert %{
               payload: %{
                 status: [
                   "cannot create :archived transactions, must be transitioned from :pending"
                 ]
               }
             } = errors_on(changeset)
    end

    test "overdrawing an account with no negative limit puts the error on the entry amount",
         %{instance: instance} do
      params = transaction_params(instance, "posted", "bank:eur", "cash:eur", 100)

      assert {:error, changeset} = CommandApi.process_from_params(params)

      assert %{payload: %{entries: [%{}, %{amount: ["amount can't be negative"]}]}} =
               errors_on(changeset)
    end

    test "overdrawing past a negative limit puts the error on the entry amount",
         %{instance: instance} do
      params = transaction_params(instance, "posted", "bank:eur", "card:eur", 100)

      assert {:error, changeset} = CommandApi.process_from_params(params)

      assert %{
               payload: %{
                 entries: [%{}, %{amount: ["amount can't be below negative limit of -50"]}]
               }
             } =
               errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  # Moves `amount` from `credit` (entry 2) into `debit` (entry 1); both are
  # asset accounts, so the credited entry carries the negative amount.
  defp transaction_params(instance, status, debit, credit, amount) do
    %{
      "instance_address" => instance.address,
      "action" => "create_transaction",
      "source" => "api-test",
      "source_idempk" => Ecto.UUID.generate(),
      "payload" => %{
        "status" => status,
        "entries" => [
          %{"account_address" => debit, "amount" => amount, "currency" => "EUR"},
          %{"account_address" => credit, "amount" => -amount, "currency" => "EUR"}
        ]
      }
    }
  end
end
