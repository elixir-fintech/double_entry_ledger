defmodule DoubleEntryLedger.PendingTransactionLookup do
  @moduledoc """
  Lightweight correlation row keyed by external idempotency tuple.
  Creates transaction keys for andy new pending transaction to make it easier to find updates
  """

  use DoubleEntryLedger.BaseSchema
  import Ecto.Changeset

  alias DoubleEntryLedger.{Command, Transaction, JournalEvent}

  @primary_key false
  schema "pending_transaction_lookup" do
    field :source, :string, primary_key: true
    field :source_idempk, :string, primary_key: true
    field :instance_id, :string, primary_key: true

    belongs_to(:command, Command, source: :create_command_id)
    belongs_to(:transaction, Transaction)
    belongs_to(:journal_event, JournalEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @req ~w(source source_idempk instance_id)a
  @optional ~w(create_command_id transaction_id journal_event_id)a

  def upsert_changeset(struct, attrs) do
    struct
    |> cast(attrs, @req ++ @optional)
    |> validate_required(@req)
  end
end
