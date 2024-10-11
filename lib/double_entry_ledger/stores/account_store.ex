defmodule DoubleEntryLedger.AccountStore do
  @moduledoc """
  This module defines the AccountStore behaviour.
  """
  import Ecto.Query, only: [from: 2]
  alias DoubleEntryLedger.{Repo, Account}

  @spec get_accounts(list(String.t)) :: list(Account.t)
  def get_accounts(account_ids) do
    accounts = Repo.all(from a in Account, where: a.id in ^account_ids)
    if length(accounts) == length(account_ids) do
      {:ok, accounts}
    else
      {:error, "Some accounts were not found"}
    end
  end
end
