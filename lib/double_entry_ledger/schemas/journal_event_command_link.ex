defmodule DoubleEntryLedger.JournalEventCommandLink do
  @moduledoc """
  Join schema linking events and transactions in the Double Entry Ledger.

  This schema records the relationship between events (business intents) and transactions
  (ledger entries) to provide a complete audit trail. Each link represents that a specific
  event was involved in creating or updating a transaction.

  ## Fields

    * `:command_id` - References the associated event.
    * `:transaction_id` - References the associated transaction.
    * `:inserted_at` - Timestamp when the link was created.
    * `:updated_at` - Timestamp when the link was last updated.

  ## Usage

  Use this schema to query all events that affected a transaction, or all transactions
  that were affected by a specific event. This enables safe pruning of processing state
  while preserving the full business and audit history.
  """
  use DoubleEntryLedger.BaseSchema
  alias DoubleEntryLedger.{Command, JournalEvent}
  alias __MODULE__, as: JournalEventCommandLink

  @type t :: %JournalEventCommandLink{
          id: Ecto.UUID.t() | nil,
          command: Command.t() | Ecto.Association.NotLoaded.t(),
          command_id: Ecto.UUID.t() | nil,
          journal_event: Command.t() | Ecto.Association.NotLoaded.t(),
          journal_event_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "journal_event_command_links" do
    belongs_to(:command, Command)
    belongs_to(:journal_event, JournalEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(journal_event_command_link, attrs) do
    journal_event_command_link
    |> cast(attrs, [:command_id, :journal_event_id])
    |> validate_required([:command_id, :journal_event_id])
  end
end
