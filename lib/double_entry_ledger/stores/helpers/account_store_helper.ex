defmodule DoubleEntryLedger.Stores.AccountStoreHelper do
  @moduledoc """
  Helper functions for building Account changesets in the Double Entry Ledger system.

  This module provides utilities for creating and updating Account records, focusing on
  building proper Ecto changesets from AccountData structures. It serves as a bridge
  between the event processing system and the Account schema operations.

  ## Key Functionality

  * **Account Creation**: Build changesets for creating new accounts from AccountData
  * **Account Updates**: Build changesets for updating existing accounts with validation
  * **Data Transformation**: Convert AccountData structures to appropriate changeset parameters
  * **Validation**: Ensures all account data meets schema requirements before database operations

  ## Integration

  This module is primarily used by EventWorker modules when processing account-related
  events, providing a consistent interface for account changeset operations. It integrates
  directly with the Account schema's validation rules and the event sourcing system.

  ## Error Handling

  All functions return Ecto changesets that may contain validation errors. These should
  be checked for validity before attempting database operations.

  ## Examples

      # Building a create changeset
      account_data = %AccountData{name: "Cash", type: :asset, currency: :USD}
      changeset = AccountStoreHelper.build_create(account_data, instance_id)

      if changeset.valid? do
        Repo.insert(changeset)
      else
        # Handle validation errors
      end

      # Building an update changeset
      changeset = AccountStoreHelper.build_update(existing_account, updated_data)
  """
  import Ecto.Query, only: [from: 2]

  alias DoubleEntryLedger.Account
  alias DoubleEntryLedger.Event.AccountData

  @doc """
  Builds a changeset for creating a new Account from AccountData.

  Takes an AccountData struct containing the account information and combines it
  with the provided instance_id to create a complete changeset for Account creation.
  The changeset includes all necessary validations defined in the Account schema.

  ## Parameters

  * `account_data` - AccountData struct containing account details (address, type, currency, etc.)
  * `instance_id` - UUID of the ledger instance to associate the account with

  ## Returns

  * `Ecto.Changeset.t(Account.t())` - A changeset ready for database insertion

  ## Validation

  The returned changeset will validate:
  * Required fields (address, type, currency, instance_id)
  * Account type validity (asset, liability, equity, income, expense)
  * Currency format and validity
  * Address uniqueness within the instance
  * Description length limits (if provided)

  ## Examples

      iex> alias DoubleEntryLedger.Stores.AccountStore
      iex> alias DoubleEntryLedger.Stores.InstanceStore
      iex> alias DoubleEntryLedger.Event.AccountData
      iex> {:ok, %{id: instance_id}} = InstanceStore.create(%{address: "Sample:Instance"})
      iex> account_data = %AccountData{address: "Cash:Account", type: :asset, currency: :USD}
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
  creating a changeset that represents the desired changes. Only allows updates
  to specific fields as defined by the Account schema's update policy.

  ## Parameters

  * `account` - Existing Account struct to be updated
  * `account_data` - AccountData struct containing the new values

  ## Returns

  * `Ecto.Changeset.t(Account.t())` - A changeset ready for database update

  ## Updateable Fields

  Only the following fields can be updated:
  * `name` - Account display name
  * `description` - Account description text
  * `context` - Additional contextual information (JSON)

  Fields like address, type, currency and instance_id are immutable after creation.

  ## Validation

  The returned changeset will validate:
  * Context format (must be valid JSON if provided)
  * No changes to immutable fields

  ## Examples

      iex> alias DoubleEntryLedger.Account
      iex> alias DoubleEntryLedger.Stores.AccountStoreHelper
      iex> alias DoubleEntryLedger.Event.AccountData
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


  @spec get_by_address_query(String.t(), String.t()) :: Ecto.Query.t()
  def get_by_address_query(instance_address, account_address) do
    from(a in Account,
      join: i in assoc(a, :instance),
      where: a.address == ^account_address and i.address == ^instance_address,
      preload: [:events]
    )
  end
end
