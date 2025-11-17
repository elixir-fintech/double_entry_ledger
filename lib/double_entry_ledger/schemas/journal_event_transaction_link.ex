defmodule DoubleEntryLedger.JournalEventTransactionLink do
  @moduledoc """
  Join schema linking events and transactions in the Double Entry Ledger.

  This schema records the relationship between events (business intents) and transactions
  (ledger entries) to provide a complete audit trail. Each link represents that a specific
  event was involved in creating or updating a transaction.

  ## Fields

    * `:transaction_id` - References the associated transaction.
    * `:inserted_at` - Timestamp when the link was created.
    * `:updated_at` - Timestamp when the link was last updated.

  ## Usage

  Use this schema to query all events that affected a transaction, or all transactions
  that were affected by a specific event. This enables safe pruning of processing state
  while preserving the full business and audit history.
  """
  use DoubleEntryLedger.BaseSchema
  alias DoubleEntryLedger.{Command, Transaction, JournalEvent}
  alias __MODULE__, as: JournalEventTransactionLink

  @type t :: %JournalEventTransactionLink{
          id: Ecto.UUID.t() | nil,
          transaction: Transaction.t() | Ecto.Association.NotLoaded.t(),
          transaction_id: Ecto.UUID.t() | nil,
          journal_event: Command.t() | Ecto.Association.NotLoaded.t(),
          journal_event_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "journal_event_transaction_links" do
    belongs_to(:transaction, Transaction)
    belongs_to(:journal_event, JournalEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event_transaction_link, attrs) do
    event_transaction_link
    |> cast(attrs, [:transaction_id, :journal_event_id])
    |> validate_required([:transaction_id, :journal_event_id])
  end
end
