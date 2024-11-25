defmodule DoubleEntryLedger.Schemas.BalanceHistoryEntry do
  @moduledoc """
  Provides the schema for the balance history entry.
  This schema is used to store the balance history of an account.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias DoubleEntryLedger.{Account, Entry}
  alias __MODULE__, as: BalanceHistoryEntry

  @type t :: %BalanceHistoryEntry{
    id: Ecto.UUID.t(),
    posted: map(),
    pending: map(),
    available: integer(),
    account: Account.t() | Ecto.Association.NotLoaded.t(),
    account_id: Ecto.UUID.t(),
    entry: Entry.t() | Ecto.Association.NotLoaded.t(),
    entry_id: Ecto.UUID.t(),
    inserted_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "balance_history_entries" do
    field :available, :integer, default: 0

    embeds_one(:posted, Balance, on_replace: :delete)
    embeds_one(:pending, Balance, on_replace: :delete)

    belongs_to :account, Account
    belongs_to :entry, Entry

    timestamps(type: :utc_datetime_usec)
  end

end
