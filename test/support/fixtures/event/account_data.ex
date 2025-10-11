defmodule DoubleEntryLedger.Event.AccountDataFixtures do
  @moduledoc"""
  AccountData fixtures
  """
  alias DoubleEntryLedger.Event.AccountData

  def account_data_params(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      address: "account:1",
      type: :asset,
      currency: "EUR"
    })
  end

  def account_data_attrs(attrs \\ %{}) do
    account_data_params(attrs)
    |> then(&struct(AccountData, &1))
  end
end
