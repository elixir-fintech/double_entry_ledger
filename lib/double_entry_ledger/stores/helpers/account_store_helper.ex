defmodule DoubleEntryLedger.AccountStoreHelper do
  alias DoubleEntryLedger.Account
  alias DoubleEntryLedger.Event.AccountData

  @spec build_create(AccountData.t(), Ecto.UUID.t()) :: Ecto.Changeset.t(Account.t())
  def build_create(%AccountData{} = account_data, instance_id) do
    account_params = Map.put(AccountData.to_map(account_data), :instance_id, instance_id)

    %Account{}
    |> Account.changeset(account_params)
  end
end
