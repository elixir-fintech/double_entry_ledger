defmodule DoubleEntryLedger.Event.TransactionData do
  @moduledoc """
  Provides the TransactionData embedded schema for the Double Entry Ledger system.

  This module defines a schema that represents the core transaction information within events,
  containing both the transaction status and a collection of related entries. It serves as
  an intermediate representation before a transaction is persisted to the database.

  ## Structure

  TransactionData contains:

  * `status` - The current state of the transaction (e.g., `:pending`, `:posted`)
  * `entries` - A list of EntryData structs representing the individual account entries

  ## Validation Rules

  The module enforces several business rules during validation:

  * Transactions must have at least 2 entries
  * Each entry must affect a different account (no duplicate account IDs)
  * Status values must be one of the allowed transaction states

  ## Status Transitions

  Different validation rules apply depending on the status transition:

  * When posting a transaction (status → `:posted`), entries are optional
  * When archiving a transaction (status → `:archived`), only status is validated
  * For all other changes, full validation rules apply

  ## Usage Examples

  Creating a new transaction with entries:

      changeset = TransactionData.changeset(%TransactionData{}, %{
        status: :pending,
        entries: [
          %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db8", amount: 100, currency: :USD},
          %{account_id: "c24a758c-7300-4e94-a2fe-d2dc9b1c2db7", amount: -100, currency: :USD}
        ]
      })

  Updating a transaction's status to posted:

      updated_changeset = TransactionData.update_event_changeset(existing_transaction, %{status: :posted})

  Converting to a plain map:

      map = TransactionData.to_map(transaction_data)
      # %{status: :pending, entries: [%{account_id: "...", amount: 100, currency: :USD}, ...]}
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states DoubleEntryLedger.Transaction.states()

  @posted ["posted", :posted]
  @archived ["archived", :archived]

  alias DoubleEntryLedger.Transaction
  alias DoubleEntryLedger.Event.EntryData
  alias __MODULE__, as: TransactionData

  @derive {Jason.Encoder, only: [:status, :entries]}

  @typedoc """
  Represents a transaction with its status and collection of entries.

  This type defines the structure of transaction data used in events and includes:

  * `status`: The transaction's current state (e.g., :pending, :posted, :archived)
  * `entries`: A list of EntryData structs that make up the financial entries

  This type is commonly used when creating or updating transactions through the event system.
  """
  @type t :: %TransactionData{
          status: Transaction.state() | nil,
          entries: [EntryData.t()] | []
        }

  @primary_key false
  embedded_schema do
    field(:status, Ecto.Enum, values: @states)
    embeds_many(:entries, EntryData, on_replace: :delete)
  end

  @doc """
  Creates a changeset for validating TransactionData attributes.

  This function builds an Ecto changeset that validates the required fields
  and structure of transaction data, enforcing business rules like requiring
  at least two entries with distinct account IDs.

  ## Parameters
    - `transaction_data`: The TransactionData struct to create a changeset for
    - `attrs`: Map of attributes to apply to the struct

  ## Returns
    - An Ecto.Changeset with validations applied

  ## Validation Rules
    - Status must be a valid transaction state
    - Must have at least 2 entries
    - Each entry must affect a different account

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionData
      iex> attrs = %{status: :pending, entries: [
      ...>   %{account_address: "asset:account", amount: 100, currency: :USD},
      ...>   %{account_address: "cash:account", amount: -100, currency: :USD}
      ...> ]}
      iex> changeset = TransactionData.changeset(%TransactionData{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction_data, attrs) do
    transaction_data
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @states)
    |> cast_embed(:entries, with: &EntryData.changeset/2, required: true)
    |> validate_entries_count()
    |> validate_distinct_account_ids()
  end

  @doc """
  Creates a changeset specifically for update events, with conditional validation.

  This function applies different validation rules based on the transaction status
  being updated. When posting or archiving a transaction, less strict validation is applied.

  ## Parameters
    - `transaction_data`: The TransactionData struct to create a changeset for
    - `attrs`: Map of attributes to apply to the struct

  ## Returns
    - An Ecto.Changeset with appropriate validations applied

  ## Status-Based Rules
    - When transitioning to `:posted` without entries: Only validates status
    - When transitioning to `:archived`: Only validates status
    - For other changes: Applies full validation rules

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionData
      iex> # Posting without entries is allowed
      iex> changeset = TransactionData.update_event_changeset(%TransactionData{}, %{status: :posted})
      iex> changeset.valid?
      true

      iex> # Archiving is allowed
      iex> changeset = TransactionData.update_event_changeset(%TransactionData{}, %{status: :archived})
      iex> changeset.valid?
      true
  """
  @spec update_event_changeset(t() | %{}, map()) :: Ecto.Changeset.t()
  def update_event_changeset(transaction_data, attrs) do
    # Extract status and entries from attrs regardless of key type.
    status = Map.get(attrs, "status") || Map.get(attrs, :status)
    entries = Map.get(attrs, "entries") || Map.get(attrs, :entries)

    cond do
      entries in [[], nil] and status in @posted ->
        cast(transaction_data, attrs, [:status])

      status in @archived ->
        cast(transaction_data, attrs, [:status])

      true ->
        changeset(transaction_data, attrs)
    end
  end

  @doc """
  Converts the given `TransactionData.t` struct to a map.

  ## Examples

      iex> alias DoubleEntryLedger.Event.TransactionData
      iex> transaction_data = %TransactionData{}
      iex> TransactionData.to_map(transaction_data)
      %{status: nil, entries: []}

  """
  @spec to_map(t()) :: map()
  def to_map(nil), do: %{}

  def to_map(td) do
    %{
      status: Map.get(td, :status),
      entries: Enum.map(Map.get(td, :entries, []), &EntryData.to_map/1)
    }
  end

  defp validate_entries_count(changeset) do
    entries = get_field(changeset, :entries, [])

    cond do
      entries == [] ->
        add_error(changeset, :entry_count, "must have at least 2 entries")

      length(entries) == 1 ->
        add_error(changeset, :entry_count, "must have at least 2 entries")
        |> add_errors_to_entries(:account_address, "at least 2 accounts are required")

      true ->
        changeset
    end
  end

  defp validate_distinct_account_ids(changeset) do
    duplicate_addresses =
      (get_embed(changeset, :entries, :struct) || [])
      |> Enum.map(& &1.account_address)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {id, _} -> id end)

    if duplicate_addresses != [] do
      add_errors_to_entries(
        changeset,
        :account_address,
        "account addresses must be distinct",
        duplicate_addresses
      )
    else
      changeset
    end
  end

  @spec add_errors_to_entries(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  defp add_errors_to_entries(changeset, field, error) do
    (get_embed(changeset, :entries, :changeset) || [])
    |> Enum.map(&add_error(&1, field, error))
    |> then(&put_embed(changeset, :entries, &1))
  end

  @spec add_errors_to_entries(Ecto.Changeset.t(), atom(), String.t(), list(Ecto.UUID.t())) ::
          Ecto.Changeset.t()
  defp add_errors_to_entries(changeset, field, error, ids) do
    (get_embed(changeset, :entries, :changeset) || [])
    |> Enum.map(fn entry_changeset ->
      id = get_field(entry_changeset, field)

      if id in ids do
        add_error(entry_changeset, field, error)
      else
        entry_changeset
      end
    end)
    |> then(&put_embed(changeset, :entries, &1))
  end
end
