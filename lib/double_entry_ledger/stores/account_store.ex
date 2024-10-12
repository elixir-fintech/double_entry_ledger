defmodule DoubleEntryLedger.AccountStore do
  @moduledoc """
  This module defines the AccountStore behaviour.
  """
  import Ecto.Query, only: [from: 2]
  alias DoubleEntryLedger.{Repo, Account}

  @spec get_accounts_by_instance_id(Ecto.UUID.t(), list(String.t())) :: {:error, String.t()} | {:ok, list(Account.t())}
  def get_accounts_by_instance_id(instance_id, account_ids) do
    accounts = Repo.all(
      from a in Account,
      where: a.instance_id == ^instance_id and a.id in ^account_ids
    )
    if length(accounts) == length(account_ids) do
      {:ok, accounts}
    else
      {:error, "Some accounts were not found"}
    end
  end

  @spec get_all_accounts_by_instance_id(Ecto.UUID.t()) :: {:error, String.t()} | {:ok, list(Account.t())}
  def get_all_accounts_by_instance_id(instance_id) do
    accounts = Repo.all(from a in Account, where: a.instance_id == ^instance_id)
    if length(accounts) > 0 do
      {:ok, accounts}
    else
      {:error, "No accounts were found"}
    end
  end
end
