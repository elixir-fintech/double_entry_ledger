defmodule DoubleEntryLedger.EventAccountLink do
  @moduledoc """
  Schema for linking events and accounts.
  """
  use DoubleEntryLedger.BaseSchema
  alias DoubleEntryLedger.{Event, Account}
  alias __MODULE__, as: EventAccountLink

  @type t() :: %EventAccountLink{
          id: Ecto.UUID.t() | nil,
          event_id: Ecto.UUID.t() | nil,
          event: Event.t() | Ecto.Association.NotLoaded.t(),
          account_id: Ecto.UUID.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "event_account_links" do
    belongs_to(:event, Event)
    belongs_to(:account, Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns a changeset for the given `EventAccountLink` and `attrs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t(t())
  def changeset(%EventAccountLink{} = event_account_link, attrs) do
    event_account_link
    |> cast(attrs, [:event_id, :account_id])
    |> validate_required([:event_id, :account_id])
  end
end
