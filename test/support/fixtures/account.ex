defmodule DoubleEntryLedger.AccountFixtures do
  @moduledoc """
  This module defines test helpers for creating
  account entities.
  """

  alias DoubleEntryLedger.{Account, Balance, Repo}

  @doc """
  Generate a account.
  """
  def account_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        currency: :EUR,
        description: "some description",
        posted: Map.from_struct(%Balance{}),
        pending: Map.from_struct(%Balance{}),
        available: 0,
        context: %{},
        name: "some name",
        type: :debit,
      })

    {:ok, account} =
      %Account{}
      |> Account.changeset(attrs)
      |> Repo.insert()

    account
  end
end
