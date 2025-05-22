defmodule DoubleEntryLedger.EventTransactionLink do
  @moduledoc """
  Join schema linking events and transactions in the Double Entry Ledger.

  This schema records the relationship between events (business intents) and transactions
  (ledger entries) to provide a complete audit trail. Each link represents that a specific
  event was involved in creating or updating a transaction.

  ## Fields

    * `:event_id` - References the associated event.
    * `:transaction_id` - References the associated transaction.
    * `:inserted_at` - Timestamp when the link was created.
    * `:updated_at` - Timestamp when the link was last updated.

  ## Usage

  Use this schema to query all events that affected a transaction, or all transactions
  that were affected by a specific event. This enables safe pruning of processing state
  while preserving the full business and audit history.
  """
  use DoubleEntryLedger.BaseSchema
  alias DoubleEntryLedger.{Event, Transaction}
  alias __MODULE__, as: EventTransactionLink

  @type t :: %EventTransactionLink{
          id: Ecto.UUID.t() | nil,
          event: Event.t() | Ecto.Association.NotLoaded.t(),
          event_id: Ecto.UUID.t() | nil,
          transaction: Transaction.t() | Ecto.Association.NotLoaded.t(),
          transaction_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "event_transaction_links" do
    belongs_to(:event, Event)
    belongs_to(:transaction, Transaction)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event_transaction_link, attrs) do
    event_transaction_link
    |> cast(attrs, [:event_id, :transaction_id])
    |> validate_required([:event_id, :transaction_id])
  end
end
