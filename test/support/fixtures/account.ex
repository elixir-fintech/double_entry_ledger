defmodule DoubleEntryLedger.AccountFixtures do
  @moduledoc """
  This module defines test helpers for creating
  account entities.
  """

  alias DoubleEntryLedger.{Account, Balance, Repo}
  alias DoubleEntryLedger.Stores.AccountStore

  @doc """
  Generate a account.
  """
  def account_fixture(attrs \\ %{}) do
    random_name =
      "account_#{:crypto.strong_rand_bytes(4) |> Base.encode64() |> binary_part(0, 8)}"

    address = "account:main#{:rand.uniform(1_000_000)}"

    attrs =
      attrs
      |> Enum.into(%{
        currency: :EUR,
        description: "some description",
        posted: Map.from_struct(%Balance{}),
        pending: Map.from_struct(%Balance{}),
        available: 0,
        context: %{},
        name: random_name,
        address: address,
        type: :asset,
        normal_balance: :debit
      })

    {:ok, account} =
      %Account{}
      |> Account.changeset(attrs)
      |> Repo.insert()

    account
  end

  def account_payload_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      address: "account:1",
      type: :asset,
      currency: "EUR"
    })
  end

  def create_accounts(%{instance: instance}) do
    %{
      instance: instance,
      accounts: [
        account_fixture(instance_id: instance.id, type: :asset, normal_balance: :debit),
        account_fixture(instance_id: instance.id, normal_balance: :credit, type: :liability),
        account_fixture(
          instance_id: instance.id,
          normal_balance: :debit,
          type: :asset,
          allowed_negative: false
        ),
        account_fixture(
          instance_id: instance.id,
          normal_balance: :credit,
          type: :liability,
          allowed_negative: false
        )
      ]
    }
  end

  def return_available_balances(ctx, items \\ 2) do
    accounts(ctx, items)
    |> Enum.map(& &1.available)
  end

  def return_pending_balances(ctx, items \\ 2) do
    accounts(ctx, items)
    |> Enum.map(& &1.pending.amount)
  end

  def return_posted_balances(ctx, items \\ 2) do
    accounts(ctx, items)
    |> Enum.map(& &1.posted.amount)
  end

  defp accounts(%{instance: inst, accounts: ctx_accounts}, items) do
    account_addresses = ctx_accounts |> Enum.take(items) |> Enum.map(& &1.address)
    {:ok, accounts} = AccountStore.get_accounts_by_instance_id(inst.id, account_addresses)
    accounts
  end
end
