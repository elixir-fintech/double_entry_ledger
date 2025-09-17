defmodule DoubleEntryLedger.AccountStoreHelper do
  @moduledoc """
  Helper functions for building Account changesets in the Double Entry Ledger system.

  This module provides utilities for creating and updating Account records, focusing on
  building proper Ecto changesets from AccountData structures. It serves as a bridge
  between the event processing system and the Account schema operations.

  ## Key Functionality

  * **Account Creation**: Build changesets for creating new accounts from AccountData
  * **Account Updates**: Build changesets for updating existing accounts
  * **Data Transformation**: Convert AccountData structures to appropriate changeset parameters

  ## Usage

  This module is primarily used by EventWorker modules when processing account-related
  events, providing a consistent interface for account changeset operations.

  ## Examples

      # Building a create changeset
      account_data = %AccountData{name: "Cash", type: :asset, currency: :USD}
      changeset = AccountStoreHelper.build_create(account_data, instance_id)

      # Building an update changeset
      changeset = AccountStoreHelper.build_update(existing_account, updated_data)
  """

  alias DoubleEntryLedger.Account
  alias DoubleEntryLedger.Event.AccountData

  @doc """
  Builds a changeset for creating a new Account from AccountData.

  Takes an AccountData struct containing the account information and combines it
  with the provided instance_id to create a complete changeset for Account creation.

  ## Parameters

  * `account_data` - AccountData struct containing account details (name, type, currency, etc.)
  * `instance_id` - UUID of the ledger instance to associate the account with

  ## Returns

  * `Ecto.Changeset.t(Account.t())` - A changeset ready for database insertion

  ## Examples

      iex> account_data = %AccountData{name: "Cash Account", type: :asset, currency: :USD}
      iex> changeset = AccountStoreHelper.build_create(account_data, instance_id)
      iex> changeset.valid?
      true
  """
  @spec build_create(AccountData.t(), Ecto.UUID.t()) :: Ecto.Changeset.t(Account.t())
  def build_create(%AccountData{} = account_data, instance_id) do
    account_params = Map.put(AccountData.to_map(account_data), :instance_id, instance_id)

    %Account{}
    |> Account.changeset(account_params)
  end

  @doc """
  Builds a changeset for updating an existing Account with new AccountData.

  Takes an existing Account record and AccountData containing the updates,
  creating a changeset that represents the desired changes.

  ## Parameters

  * `account` - Existing Account struct to be updated
  * `account_data` - AccountData struct containing the new values

  ## Returns

  * `Ecto.Changeset.t(Account.t())` - A changeset ready for database update

  ## Examples

      iex> existing_account = %Account{name: "Old Name", type: :asset, currency: :USD}
      iex> new_data = %AccountData{description: "Updated Description"}
      iex> changeset = AccountStoreHelper.build_update(existing_account, new_data)
      iex> changeset.valid?
      true
  """
  @spec build_update(Account.t(), AccountData.t()) :: Ecto.Changeset.t(Account.t())
  def build_update(%Account{} = account, account_data) do
    account
    |> Account.update_changeset(AccountData.to_map(account_data))
  end
end
