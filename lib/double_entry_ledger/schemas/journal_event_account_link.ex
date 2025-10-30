defmodule DoubleEntryLedger.JournalEventAccountLink do
  @moduledoc """
  Schema for linking events and accounts.
  """
  use DoubleEntryLedger.BaseSchema
  alias DoubleEntryLedger.{Account, JournalEvent}
  alias __MODULE__, as: JournalEventAccountLink

  @type t() :: %JournalEventAccountLink{
          id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          journal_event_id: Ecto.UUID.t() | nil,
          journal_event: JournalEvent.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "journal_event_account_links" do
    belongs_to(:account, Account)
    belongs_to(:journal_event, JournalEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns a changeset for the given `JournalEventAccountLink` and `attrs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t(t())
  def changeset(%JournalEventAccountLink{} = event_account_link, attrs) do
    event_account_link
    |> cast(attrs, [:account_id, :journal_event_id])
    |> validate_required([:account_id, :journal_event_id])
  end
end
