defmodule DoubleEntryLedger.PendingTransactionLookup do
  @moduledoc """
  Lightweight correlation row keyed by external idempotency tuple.
  Creates transaction keys for andy new pending transaction to make it easier to find updates
  """

  use DoubleEntryLedger.BaseSchema
  import Ecto.Changeset

  alias __MODULE__, as: PendingTransactionLookup
  alias DoubleEntryLedger.{Instance, Command, Transaction, JournalEvent}

  @type t :: %PendingTransactionLookup{
    source: String.t(),
    source_idempk: String.t(),
    instance_id: Ecto.UUID.t(),
    instance: Instance.t() | Ecto.Association.NotLoaded.t(),
    command_id: Ecto.UUID.t(),
    command: Command.t() | Ecto.Association.NotLoaded.t(),
    transaction_id: Ecto.UUID.t() | nil,
    transaction: Transaction.t() | Ecto.Association.NotLoaded.t() | nil,
    journal_event_id: Ecto.UUID.t(),
    journal_event: JournalEvent.t() | Ecto.Association.NotLoaded.t() | nil
  }

  @primary_key false
  schema "pending_transaction_lookup" do
    field(:source, :string, primary_key: true)
    field(:source_idempk, :string, primary_key: true)
    belongs_to(:instance, Instance, primary_key: true)

    belongs_to(:command, Command)
    belongs_to(:transaction, Transaction)
    belongs_to(:journal_event, JournalEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @req ~w(source source_idempk instance_id)a
  @optional ~w(command_id transaction_id journal_event_id)a

  def upsert_changeset(struct, attrs) do
    struct
    |> cast(attrs, @req ++ @optional)
    |> validate_required(@req)
    |> unique_constraint(@req, name: "pending_transaction_lookup_pkey")
  end
end
