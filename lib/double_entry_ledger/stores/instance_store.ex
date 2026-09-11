defmodule DoubleEntryLedger.Stores.InstanceStore do
  @moduledoc """
  Provides functions for managing ledger instances in the double-entry ledger system.

  This module serves as the primary interface for all ledger instance operations, including
  creating, retrieving, updating, and deleting instances. It also provides specialized
  queries to verify ledger integrity through balance verification across currencies.

  ## Key Functionality

  * **Instance Management**: Create, retrieve, update, and delete ledger instances
  * **Instance Queries**: Find and list instances by various criteria
  * **Balance Verification**: Calculate and verify that total debits equal total credits by currency
  * **Transaction Safety**: Ensures critical operations use appropriate database isolation levels

  ## Usage Examples

  Creating a new ledger instance:

      {:ok, instance} = DoubleEntryLedger.Stores.InstanceStore.create(%{
        address: "Business Ledger",
        metadata: %{owner: "ACME Corp"}
      })

  Retrieving and updating an instance:

      instance = DoubleEntryLedger.Stores.InstanceStore.get_by_id(instance_id)
      {:ok, updated_instance} = DoubleEntryLedger.Stores.InstanceStore.update(
        instance.id,
        %{address: "Updated:Ledger:address"}
      )

  Verifying ledger balance integrity:

      {:ok, currency_balances} = InstanceStore.sum_accounts_debits_and_credits_by_currency(instance.id)
      # Check that for each currency, debits = credits

  ## Implementation Notes

  All functions perform appropriate validation and return standardized results:

  * Success: `{:ok, result}`
  * Error: `{:error, reason}`

  Balance verification queries run in transactions with REPEATABLE READ isolation
  to ensure consistency when concurrent operations are taking place.
  """
  import Ecto.Query, only: [from: 2]
  alias DoubleEntryLedger.{Instance, Account, Telemetry}
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Stores.InstanceStoreHelper

  @doc """
  Creates a new ledger instance with the given attributes.

  ## Parameters

    - `attrs` (map): A map of attributes for the ledger instance.

  ## Returns

    - `{:ok, instance}`: On success.
    - `{:error, changeset}`: If there was an error during creation.

  ## Examples

      iex> attrs = %{address: "Test:Ledger"}
      iex> {:ok, instance} = InstanceStore.create(attrs)
      iex> instance.address
      "Test:Ledger"

  """
  @spec create(map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    case %Instance{}
         |> Instance.changeset(attrs)
         |> Repo.insert() do
      {:ok, instance} = result ->
        Telemetry.instance_created(%{instance_id: instance.id})
        result

      error ->
        error
    end
  end

  @doc """
  Lists ledger instances with cursor pagination via `Flop`.

  ## Parameters

    - `flop_params` (map, optional): Flop parameter map. Common keys:
      - `:first` / `:after` — cursor forward pagination
      - `:last` / `:before` — cursor backward pagination
      - `:filters` — list of `%{field: atom, op: atom, value: any}` (only `:address` is allow-listed)
      - `:order_by` / `:order_directions` — override default `[inserted_at desc, id desc]`

  ## Returns

    - `{:ok, {[Instance.t()], Flop.Meta.t()}}` on success.
    - `{:error, Flop.Meta.t()}` if params fail validation (e.g. filtering on a non-allow-listed field).

  ## Examples

      iex> {:ok, %{id: id}} = InstanceStore.create(%{address: "Sample:Ledger"})
      iex> {:ok, {[%{id: ^id}], %Flop.Meta{}}} = InstanceStore.list()
  """
  @spec list(map()) ::
          {:ok, {[Instance.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list(flop_params \\ %{}) do
    DoubleEntryLedger.Flop.validate_and_run(Instance, flop_params, for: Instance)
  end

  @doc """
  Retrieves a ledger instance by its ID.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the ledger instance.

  ## Returns

    - `instance`: The ledger instance struct, or `nil` if not found.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Ledger"})
      iex> retrieved = InstanceStore.get_by_id(instance.id)
      iex> retrieved.id == instance.id
      true

  """
  @spec get_by_id(Ecto.UUID.t()) :: Instance.t() | nil
  def get_by_id(id) do
    Repo.get(Instance, id)
  end

  @spec get_by_address(String.t()) :: Instance.t() | nil
  def get_by_address(address) do
    Repo.one(InstanceStoreHelper.build_get_by_address(address))
  end

  @doc """
  Updates a ledger instance with the given attributes.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the ledger instance to update.
    - `attrs` (map): The attributes to update.

  ## Returns

    - `{:ok, instance}`: On success.
    - `{:error, changeset}`: If there was an error during update.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Ledger"})
      iex> {:ok, updated_instance} = InstanceStore.update(instance.id, %{address: "Updated:Ledger"})
      iex> updated_instance.address
      "Updated:Ledger"

  """
  @spec update(Ecto.UUID.t(), map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def update(id, attrs) do
    get_by_id(id)
    |> Instance.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a ledger instance by its ID.

  Ensures that there are no associated transactions or accounts before deletion, as defined in `Instance.delete_changeset/1`.

  ## Parameters

    - `id` (Ecto.UUID.t()): The ID of the ledger instance to delete.

  ## Returns

    - `{:ok, instance}`: On success.
    - `{:error, changeset}`: If there was an error during deletion.

  ## Examples

      iex> {:ok, instance} = InstanceStore.create(%{address: "Temporary:Ledger"})
      iex> {:ok, _} = InstanceStore.delete(instance.id)
      iex> InstanceStore.get_by_id(instance.id) == nil
      true

  """
  @spec delete(Ecto.UUID.t()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def delete(id) do
    get_by_id(id)
    |> Instance.delete_changeset()
    |> Repo.delete()
  end

  @doc """
  Calculates the sum of debits and credits for all accounts in a ledger instance, grouped by currency.

  This function runs a database query in a transaction with REPEATABLE READ isolation level to ensure
  consistent results even if accounts are being updated concurrently.

  ## Parameters

    - `instance_id` (Ecto.UUID.t()): The ID of the ledger instance.

  ## Returns

    - `{:ok, list(map)}`: On success, returns a list of maps containing currency, posted_debit,
      posted_credit, pending_debit, and pending_credit sums.
    - `{:error, reason}`: If there was an error during the transaction.

  """
  @spec sum_accounts_debits_and_credits_by_currency(Ecto.UUID.t()) ::
          {:ok, list(map())} | {:error, Ecto.Changeset.t()}
  def sum_accounts_debits_and_credits_by_currency(instance_id) do
    Repo.transaction(
      fn ->
        query =
          from(a in Account,
            where: a.instance_id == ^instance_id,
            group_by: a.currency,
            select: %{
              currency: a.currency,
              # Extract each cell as `::bigint` (not `::integer`) so
              # balances above 2,147,483,647 don't trip PG's "integer
              # out of range" check. Wrapping `sum(...)::bigint` casts
              # PG's `sum(bigint) → numeric` result back to bigint so
              # Postgrex decodes it as a regular Elixir integer (not
              # Decimal), preserving the integer contract callers
              # already depend on. The realistic ceiling rises from
              # ~$21M (in cents) to ~$92 quadrillion.
              posted_debit: fragment("(sum((posted->>'debit')::bigint))::bigint"),
              posted_credit: fragment("(sum((posted->>'credit')::bigint))::bigint"),
              pending_debit: fragment("(sum((pending->>'debit')::bigint))::bigint"),
              pending_credit: fragment("(sum((pending->>'credit')::bigint))::bigint")
            }
          )

        Repo.all(query)
      end,
      isolation: :repeatable_read
    )
  end
end
