defmodule DoubleEntryLedger.BalanceHistoryEntry do
  @moduledoc """
  Provides the schema for the balance history entry.
  This schema is used to store the balance history of an account.
  """
  require Logger
  use DoubleEntryLedger.BaseSchema
  alias DoubleEntryLedger.{Account, Entry, Balance}
  alias __MODULE__, as: BalanceHistoryEntry

  @type t :: %BalanceHistoryEntry{
    id: Ecto.UUID.t(),
    posted: Balance.t(),
    pending: Balance.t(),
    available: integer(),
    account: Account.t() | Ecto.Association.NotLoaded.t(),
    account_id: Ecto.UUID.t(),
    entry: Entry.t() | Ecto.Association.NotLoaded.t(),
    entry_id: Ecto.UUID.t(),
    inserted_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  schema "balance_history_entries" do
    field :available, :integer, default: 0

    embeds_one(:posted, Balance, on_replace: :delete)
    embeds_one(:pending, Balance, on_replace: :delete)

    belongs_to :account, Account
    belongs_to :entry, Entry

    timestamps(type: :utc_datetime_usec)
  end

  @spec build_from_account_changeset(Changeset.t()) :: Changeset.t()
  def build_from_account_changeset(account_changeset) do
    %BalanceHistoryEntry{}
    |> cast(%{
        account_id: get_field(account_changeset, :id),
        available: get_field(account_changeset, :available),
      }, [:available, :account_id])
    |> put_embed(:posted, Balance.changeset(%Balance{}, Map.from_struct(get_embed(account_changeset, :posted, :struct))))
    |> put_embed(:pending, Balance.changeset(%Balance{}, Map.from_struct(get_embed(account_changeset, :pending, :struct))))
  end
end
