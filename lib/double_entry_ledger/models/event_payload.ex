defmodule DoubleEntryLedger.EventPayload do
  @moduledoc """
    EventPayload
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.EventPayload.TransactionData

  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :instance_id, Ecto.UUID
    embeds_one :transaction, TransactionData
  end

  @doc false
  def changeset(event_payload, attrs) do
    event_payload
    |> cast(attrs, [:instance_id])
    |> validate_required([:instance_id])
    |> cast_embed(:transaction, with: &TransactionData.changeset/2, required: true)
  end
end

defmodule DoubleEntryLedger.EventPayload.TransactionData do
  @moduledoc """
    TransactionData for the Event payload
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states [:posted, :pending, :archived]

  alias DoubleEntryLedger.EventPayload.EntryData

  @primary_key false
  embedded_schema do
    field :effective_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @states
    embeds_many :entries, EntryData
  end

  @doc false
  def changeset(transaction_data, attrs) do
    transaction_data
    |> cast(attrs, [:effective_at, :status])
    |> validate_required([:effective_at, :status])
    |> validate_inclusion(:status, @states)
    |> cast_embed(:entries, with: &EntryData.changeset/2, required: true)
  end
end

defmodule DoubleEntryLedger.EventPayload.EntryData do
  @moduledoc """
    EntryData for the Event payload
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.Currency

  @currency_atoms Currency.currency_atoms()

  @primary_key false
  embedded_schema do
    field :account_id, Ecto.UUID
    field :amount, :integer, default: 0
    field :currency, Ecto.Enum, values: @currency_atoms, default: :EUR
  end

  @doc false
  def changeset(entry_data, attrs) do
    entry_data
    |> cast(attrs, [:account_id, :amount, :currency])
    |> validate_required([:account_id, :amount, :currency])
    |> validate_inclusion(:currency, @currency_atoms)
  end
end
