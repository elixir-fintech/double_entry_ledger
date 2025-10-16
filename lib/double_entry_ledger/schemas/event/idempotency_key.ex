defmodule DoubleEntryLedger.Event.IdempotencyKey do
  @moduledoc """
  Idempotency Key
  """
  use DoubleEntryLedger.BaseSchema

  import Ecto.Changeset, only: [change: 2, unique_constraint: 3]

  alias __MODULE__, as: IdempotencyKey
  alias DoubleEntryLedger.Instance

  @type t() :: %IdempotencyKey{
    instance_id: Ecto.UUID.t(),
    key_hash: binary(),
    first_seen_at: DateTime.t()
  }

  @primary_key false
  schema "idempotency_keys" do
    belongs_to(:instance, Instance)
    field(:key_hash, :binary)
    field(:first_seen_at, :utc_datetime_usec)
  end

  @spec changeset(Ecto.UUID.t(), map()) :: Ecto.Changeset.t(IdempotencyKey.t())
  def changeset(instance_id, %{action: a, source: s, source_idempk: sid} = event) do
    key_hash = case Map.get(event, :update_idempk) do
      nil -> key_hash("#{a}|#{s}|#{sid}")
      uid -> key_hash("#{a}|#{s}|#{sid}|#{uid}")
    end

    %IdempotencyKey{}
    |> change(%{instance_id: instance_id, key_hash: key_hash})
    |> unique_constraint([:instance_id, :key_hash], message: "already_exists", error_key: :key_hash)
  end

  @spec key_hash(binary) :: binary
  def key_hash(idempotency_key) when is_binary(idempotency_key) do
    :crypto.mac(:hmac, :sha256, secret(), idempotency_key)
  end

  # just for debugging
  @spec key_hash_hex(binary()) :: binary()
  def key_hash_hex(idempotency_key) do
    key_hash(idempotency_key) |> Base.encode16(case: :lower)
  end

  @spec secret() :: binary()
  defp secret() do
    Application.fetch_env!(:double_entry_ledger, :idempotency_secret)
  end
end
