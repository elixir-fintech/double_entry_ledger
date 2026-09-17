defmodule DoubleEntryLedger.CommandQueueLeaseRow do
  @moduledoc """
  One row per ledger recording which processor owns it. Written only by
  `DoubleEntryLedger.CommandQueue.Lease`; read by discovery and tests. All
  timestamps come from the PostgreSQL clock.
  """
  use Ecto.Schema

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()
  @primary_key false

  @type t :: %__MODULE__{
          instance_id: Ecto.UUID.t() | nil,
          owner_id: String.t() | nil,
          fencing_token: integer() | nil,
          expires_at: DateTime.t() | nil,
          acquired_at: DateTime.t() | nil,
          renewed_at: DateTime.t() | nil,
          released_at: DateTime.t() | nil
        }

  schema "command_queue_leases" do
    field(:instance_id, Ecto.UUID, primary_key: true)
    field(:owner_id, :string)
    field(:fencing_token, :integer)
    field(:expires_at, :utc_datetime_usec)
    field(:acquired_at, :utc_datetime_usec)
    field(:renewed_at, :utc_datetime_usec)
    field(:released_at, :utc_datetime_usec)
  end
end
