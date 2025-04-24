defmodule DoubleEntryLedger.Instance do
  @moduledoc """
  Defines and manages ledger instances in the Double Entry Ledger system.

  A ledger instance acts as a container and isolation boundary for a set of accounts
  and their transactions. Each instance represents a complete, self-contained accounting
  system with its own configuration settings.

  ## Key Concepts

  * **Instance Isolation**: Each instance maintains separate accounts and transactions
  * **Balance Integrity**: The system ensures that debits and credits remain balanced within each instance
  * **Configuration**: Instances can have custom configurations to control behavior
  * **Validation**: Methods exist to verify the accounting integrity of the ledger

  ## Common Use Cases

  * **Multi-tenant Systems**: Create separate ledger instances for each tenant
  * **Application Segmentation**: Isolate different parts of an application's accounting
  * **Testing Environments**: Maintain separate testing and production ledgers

  ## Schema Structure

  The instance schema contains basic metadata (name, description) along with
  configuration settings and associations to its accounts and transactions.
  """
  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{Account, Repo, Transaction}
  alias __MODULE__, as: Instance

  @typedoc """
  Represents a ledger instance in the Double Entry Ledger system.

  An instance acts as a container for a set of accounts and transactions,
  creating an isolation boundary for a complete accounting system.

  ## Fields

  * `id`: UUID primary key
  * `config`: Map of configuration settings for this instance
  * `description`: Optional text description
  * `name`: Human-readable instance name (required)
  * `accounts`: List of accounts belonging to this instance
  * `transactions`: List of transactions belonging to this instance
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
  @type t :: %Instance{
          id: binary() | nil,
          config: map() | nil,
          description: String.t() | nil,
          name: String.t() | nil,
          accounts: [Account.t()] | Ecto.Association.NotLoaded.t(),
          transactions: [Transaction.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc """
  Represents the aggregate balance totals across all accounts in a ledger instance.

  This map contains the summed debit and credit values for both posted and pending balances,
  used to validate the fundamental accounting equation (debits = credits) across the ledger.

  ## Keys

  * `posted_debit`: Sum of all posted debit balances across all accounts
  * `posted_credit`: Sum of all posted credit balances across all accounts
  * `pending_debit`: Sum of all pending debit balances across all accounts
  * `pending_credit`: Sum of all pending credit balances across all accounts

  Used by `validate_account_balances/1` to verify ledger balance integrity.
  """
  @type validation_map :: %{
          posted_debit: integer(),
          posted_credit: integer(),
          pending_debit: integer(),
          pending_credit: integer()
        }

  schema "instances" do
    field(:config, :map)
    field(:description, :string)
    field(:name, :string)
    has_many(:accounts, Account, foreign_key: :instance_id)
    has_many(:transactions, Transaction, foreign_key: :instance_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and creating/updating a ledger instance.

  This function builds an Ecto changeset to validate the instance data according
  to the business rules.

  ## Parameters

  * `instance` - The Instance struct to create a changeset for
  * `attrs` - Map of attributes to apply to the instance

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Validations

  * Required fields: `:name`
  * Optional fields: `:description`, `:config`

  ## Examples

      iex> instance = %Instance{}
      iex> changeset = Instance.changeset(instance, %{name: "New Ledger"})
      iex> changeset.valid?
      true

      iex> instance = %Instance{}
      iex> changeset = Instance.changeset(instance, %{})
      iex> changeset.valid?
      false
  """
  @spec changeset(Instance.t(), map()) :: Ecto.Changeset.t()
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :description, :config])
    |> validate_required([:name])
  end

  @doc """
  Creates a changeset for safely deleting a ledger instance.

  This function builds a changeset that ensures a ledger instance can only be
  deleted if it has no associated accounts or transactions, maintaining data integrity.

  ## Parameters

  * `instance` - The Instance struct to delete

  ## Returns

  * An Ecto.Changeset that will fail if the instance has accounts or transactions

  ## Constraints

  * No associated accounts allowed
  * No associated transactions allowed

  ## Examples

      iex> {:ok, instance} = Repo.insert(%Instance{name: "Temporary Ledger"})
      iex> changeset = Instance.delete_changeset(instance)
      iex> {:ok, _} = Repo.delete(changeset)


      iex> {:ok, instance} = Repo.insert(%Instance{name: "Temporary Ledger"})
      iex> DoubleEntryLedger.AccountStore.create(%{name: "Test Account", instance_id: instance.id, type: :asset, currency: :USD})
      iex> changeset = Instance.delete_changeset(instance)
      iex> {:error, _} = Repo.delete(changeset)
  """
  @spec delete_changeset(Instance.t()) :: Ecto.Changeset.t()
  def delete_changeset(instance) do
    instance
    |> change()
    |> no_assoc_constraint(:transactions)
    |> no_assoc_constraint(:accounts)
  end

  @doc """
  Validates that all accounts in the ledger instance maintain balanced debits and credits.

  This function checks for one of the fundamental principles of double-entry accounting:
  the sum of all debits must equal the sum of all credits. It verifies this separately
  for both posted and pending balances.

  ## Parameters

  * `instance` - The Instance to validate (will be preloaded with accounts)

  ## Returns

  * `{:ok, map}` - If balances are equal, with the total values
  * `{:error, reason}` - If the accounts are not balanced

  ## Example

      iex> {:ok, instance} = Repo.insert(%Instance{name: "Balanced Ledger"})
      iex> DoubleEntryLedger.AccountStore.create(%{name: "Test Account", instance_id: instance.id, type: :asset, currency: :USD, posted: %{amount: 10, debit: 10, credit: 0}})
      iex> DoubleEntryLedger.AccountStore.create(%{name: "Test Account 2", instance_id: instance.id, type: :liability, currency: :USD, posted: %{amount: 10, debit: 0, credit: 10}})
      iex> instance = Repo.preload(instance, [:accounts])
      iex> Instance.validate_account_balances(instance)
      {:ok, %{
        posted_debit: 10,
        posted_credit: 10,
        pending_debit: 0,
        pending_credit: 0
      }}

      iex> alias DoubleEntryLedger.{AccountStore, Balance}
      iex> {:ok, instance} = Repo.insert(%Instance{name: "Balanced Ledger"})
      iex> AccountStore.create(%{name: "Test Account", instance_id: instance.id, type: :asset, currency: :USD, posted: %{amount: 10, debit: 10, credit: 0}})
      iex> AccountStore.create(%{name: "Test Account 2", instance_id: instance.id, type: :liability, currency: :USD})
      iex> instance = Repo.preload(instance, [:accounts])
      iex> Instance.validate_account_balances(instance)
      {:error, %{
        posted_debit: 10,
        posted_credit: 0,
        pending_debit: 0,
        pending_credit: 0
      }}
  """
  @spec validate_account_balances(Instance.t()) ::
          {:ok, validation_map()} | {:error, validation_map()}
  def validate_account_balances(instance) do
    instance
    |> ledger_value()
    |> validate_equality()
  end

  @doc """
  Calculates the total value of all accounts in the ledger instance.

  This function aggregates the debit and credit balances across all accounts in
  the instance, providing a summary of the entire ledger's financial state.

  ## Parameters

  * `instance` - The Instance to calculate totals for (will be preloaded with accounts)

  ## Returns

  * A map containing the aggregated balances:
    * `:posted_debit` - Sum of all posted debit balances
    * `:posted_credit` - Sum of all posted credit balances
    * `:pending_debit` - Sum of all pending debit balances
    * `:pending_credit` - Sum of all pending credit balances

  ## Example

      iex> {:ok, instance} = Repo.insert(%Instance{name: "Value Ledger"})
      iex> instance = Repo.preload(instance, [:accounts])
      iex> Instance.ledger_value(instance)
      %{
        posted_debit: 0,
        posted_credit: 0,
        pending_debit: 0,
        pending_credit: 0
      }
  """
  @spec ledger_value(Instance.t()) :: validation_map()
  def ledger_value(instance) do
    acc = %{posted_debit: 0, posted_credit: 0, pending_debit: 0, pending_credit: 0}

    instance
    |> Repo.preload([:accounts])
    |> Map.get(:accounts)
    |> Enum.reduce(acc, fn account, acc ->
      acc
      |> Map.update!(:posted_debit, &(&1 + account.posted.debit))
      |> Map.update!(:posted_credit, &(&1 + account.posted.credit))
      |> Map.update!(:pending_debit, &(&1 + account.pending.debit))
      |> Map.update!(:pending_credit, &(&1 + account.pending.credit))
    end)
  end

  @spec validate_equality(validation_map()) ::
          {:ok, validation_map()} | {:error, validation_map()}
  defp validate_equality(
         %{posted_debit: pod, posted_credit: poc, pending_debit: pdd, pending_credit: pdc} = value
       ) do
    if pod == poc and pdd == pdc do
      {:ok, value}
    else
      {:error, value}
    end
  end
end
