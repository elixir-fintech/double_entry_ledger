defmodule DoubleEntryLedger.Features.StepDefinitions.TransactionPostingSteps do
  @moduledoc """
  Step definitions for transaction_posting.feature.

  Instances come from `InstanceStore.create/1`, accounts from
  `AccountStore.create/3` and transactions from
  `CommandApi.process_from_params/2`, so every scenario exercises the
  full command pipeline end to end. Balance assertions re-read the
  accounts through `AccountStore.get_by_address/2` instead of trusting
  structs captured at creation time.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.Stores.{AccountStore, InstanceStore}

  step "a ledger instance", context do
    {:ok, instance} = InstanceStore.create(%{address: "cucumber:ledger"})

    Map.put(context, :instance, instance)
  end

  step "an asset account {string} in {word}",
       %{args: [address, currency]} = context do
    create_account(context, address, :asset, currency)
  end

  step "a liability account {string} in {word}",
       %{args: [address, currency]} = context do
    create_account(context, address, :liability, currency)
  end

  step "I create a {word} transaction of {int} {word} between {string} and {string}",
       %{args: [status, amount, currency, from, to]} = context do
    {:ok, _transaction, _command} =
      CommandApi.process_from_params(%{
        "action" => "create_transaction",
        "source" => "cucumber",
        "source_idempk" => Ecto.UUID.generate(),
        "instance_address" => context.instance.address,
        "payload" => %{
          "status" => status,
          "entries" => [
            %{"account_address" => from, "amount" => amount, "currency" => currency},
            %{"account_address" => to, "amount" => amount, "currency" => currency}
          ]
        }
      })

    context
  end

  # `:available` is a plain integer; `:posted` and `:pending` are
  # %Balance{} structs whose amount is the direction-aware total.
  step "the {word} balance of {string} is {int}",
       %{args: [kind, address, expected]} = context do
    account = AccountStore.get_by_address(context.instance.address, address)
    assert account != nil, "no account named #{inspect(address)}"

    actual =
      case String.to_existing_atom(kind) do
        :available -> account.available
        balance -> Map.fetch!(account, balance).amount
      end

    assert actual == expected
    context
  end

  defp create_account(context, address, type, currency) do
    {:ok, _account} =
      AccountStore.create(context.instance.address, %{
        address: address,
        type: type,
        currency: String.to_existing_atom(currency)
      })

    context
  end
end
